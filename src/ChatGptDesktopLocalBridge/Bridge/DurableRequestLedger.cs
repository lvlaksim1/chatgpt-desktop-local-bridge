using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ChatGptDesktopLocalBridge.Bridge;

public enum DurableExecutionState
{
    Reserved,
    Executing,
    Completed
}

public enum DurableDeliveryState
{
    NotReady,
    Pending,
    Sending,
    Delivered
}

public enum DurableReservationStatus
{
    Created,
    Duplicate,
    Conflict
}

public sealed record DurableRequestRecord(
    string Schema,
    string Session,
    string RequestId,
    string Tool,
    string ConversationKey,
    string FingerprintSha256,
    DurableExecutionState ExecutionState,
    DurableDeliveryState DeliveryState,
    DateTimeOffset CreatedUtc,
    DateTimeOffset UpdatedUtc,
    bool? Ok = null,
    string? ErrorCode = null,
    long? ElapsedMs = null,
    string? PendingResultMessage = null,
    string? PendingResultSha256 = null,
    int? PendingResultBytes = null);

public sealed record DurableReservation(
    DurableReservationStatus Status,
    DurableRequestRecord Record);

public sealed class DurableRequestLedger
{
    public const string Schema = "local-bridge-request-ledger-v2";

    private readonly string _directory;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly JsonSerializerOptions _jsonOptions;

    public DurableRequestLedger(string directory)
    {
        _directory = directory;
        Directory.CreateDirectory(_directory);

        _jsonOptions = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true
        };
        _jsonOptions.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
    }

    public async Task<DurableReservation> ReserveAsync(
        BridgeRequest request,
        string conversationKey,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(conversationKey))
        {
            throw new ArgumentException("Conversation key is required.", nameof(conversationKey));
        }

        var path = GetRecordPath(request.Session, request.Id);
        var fingerprint = ComputeFingerprint(request);

        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (File.Exists(path))
            {
                return CompareExisting(
                    await ReadRecordAsync(path, cancellationToken),
                    request,
                    conversationKey,
                    fingerprint);
            }

            var now = DateTimeOffset.UtcNow;
            var record = new DurableRequestRecord(
                Schema,
                request.Session,
                request.Id,
                request.Tool,
                conversationKey,
                fingerprint,
                DurableExecutionState.Reserved,
                DurableDeliveryState.NotReady,
                now,
                now);

            try
            {
                await WriteNewAsync(path, record, cancellationToken);
                return new DurableReservation(DurableReservationStatus.Created, record);
            }
            catch (IOException) when (File.Exists(path))
            {
                return CompareExisting(
                    await ReadRecordAsync(path, cancellationToken),
                    request,
                    conversationKey,
                    fingerprint);
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    public Task<DurableRequestRecord> MarkExecutingAsync(
        DurableRequestRecord record,
        CancellationToken cancellationToken = default)
        => UpdateAsync(
            record,
            current =>
            {
                if (current.ExecutionState == DurableExecutionState.Executing)
                {
                    return current;
                }

                if (current.ExecutionState != DurableExecutionState.Reserved)
                {
                    throw new InvalidOperationException(
                        $"Cannot transition request {current.RequestId} from {current.ExecutionState} to executing.");
                }

                return current with
                {
                    ExecutionState = DurableExecutionState.Executing,
                    UpdatedUtc = DateTimeOffset.UtcNow
                };
            },
            cancellationToken);

    public Task<DurableRequestRecord> MarkCompletedAsync(
        DurableRequestRecord record,
        bool ok,
        string? errorCode,
        long elapsedMs,
        string pendingResultMessage,
        CancellationToken cancellationToken = default)
    {
        var bytes = Encoding.UTF8.GetBytes(pendingResultMessage);
        var sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

        return UpdateAsync(
            record,
            current =>
            {
                if (current.ExecutionState == DurableExecutionState.Completed)
                {
                    if (current.Ok == ok &&
                        string.Equals(current.ErrorCode, errorCode, StringComparison.Ordinal) &&
                        current.ElapsedMs == elapsedMs &&
                        string.Equals(current.PendingResultSha256, sha256, StringComparison.Ordinal))
                    {
                        return current;
                    }

                    throw new InvalidOperationException(
                        $"Request {current.RequestId} is already completed with a different outcome.");
                }

                if (current.ExecutionState != DurableExecutionState.Executing)
                {
                    throw new InvalidOperationException(
                        $"Cannot complete request {current.RequestId} from {current.ExecutionState}.");
                }

                return current with
                {
                    ExecutionState = DurableExecutionState.Completed,
                    DeliveryState = DurableDeliveryState.Pending,
                    Ok = ok,
                    ErrorCode = errorCode,
                    ElapsedMs = elapsedMs,
                    PendingResultMessage = pendingResultMessage,
                    PendingResultSha256 = sha256,
                    PendingResultBytes = bytes.Length,
                    UpdatedUtc = DateTimeOffset.UtcNow
                };
            },
            cancellationToken);
    }

    public Task<DurableRequestRecord> MarkSendingAsync(
        DurableRequestRecord record,
        CancellationToken cancellationToken = default)
        => UpdateAsync(
            record,
            current =>
            {
                if (current.ExecutionState != DurableExecutionState.Completed)
                {
                    throw new InvalidOperationException(
                        $"Cannot send request {current.RequestId} result before execution is completed.");
                }

                if (current.DeliveryState == DurableDeliveryState.Sending)
                {
                    return current;
                }

                if (current.DeliveryState != DurableDeliveryState.Pending)
                {
                    throw new InvalidOperationException(
                        $"Cannot transition request {current.RequestId} from delivery state {current.DeliveryState} to sending.");
                }

                EnsurePendingPayload(current);

                return current with
                {
                    DeliveryState = DurableDeliveryState.Sending,
                    UpdatedUtc = DateTimeOffset.UtcNow
                };
            },
            cancellationToken);

    public Task<DurableRequestRecord> MarkDeliveredAsync(
        DurableRequestRecord record,
        CancellationToken cancellationToken = default)
        => UpdateAsync(
            record,
            current =>
            {
                if (current.ExecutionState != DurableExecutionState.Completed)
                {
                    throw new InvalidOperationException(
                        $"Cannot mark request {current.RequestId} delivered before execution is completed.");
                }

                if (current.DeliveryState == DurableDeliveryState.Delivered)
                {
                    return current;
                }

                if (current.DeliveryState is not (DurableDeliveryState.Pending or DurableDeliveryState.Sending))
                {
                    throw new InvalidOperationException(
                        $"Cannot transition request {current.RequestId} from delivery state {current.DeliveryState} to delivered.");
                }

                return current with
                {
                    DeliveryState = DurableDeliveryState.Delivered,
                    PendingResultMessage = null,
                    UpdatedUtc = DateTimeOffset.UtcNow
                };
            },
            cancellationToken);

    public async Task<IReadOnlyList<DurableRequestRecord>> FindRecoverableAsync(
        string conversationKey,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(conversationKey))
        {
            return Array.Empty<DurableRequestRecord>();
        }

        await _gate.WaitAsync(cancellationToken);
        try
        {
            var records = new List<DurableRequestRecord>();

            foreach (var path in Directory.EnumerateFiles(_directory, "*.json", SearchOption.TopDirectoryOnly))
            {
                var record = await ReadRecordAsync(path, cancellationToken);
                if (!string.Equals(record.Schema, Schema, StringComparison.Ordinal) ||
                    !string.Equals(record.ConversationKey, conversationKey, StringComparison.Ordinal) ||
                    record.ExecutionState != DurableExecutionState.Completed ||
                    record.DeliveryState is not (DurableDeliveryState.Pending or DurableDeliveryState.Sending))
                {
                    continue;
                }

                EnsurePendingPayload(record);
                records.Add(record);
            }

            return records
                .OrderBy(record => record.CreatedUtc)
                .ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

    public static void ValidatePendingPayload(DurableRequestRecord record)
        => EnsurePendingPayload(record);

    private async Task<DurableRequestRecord> UpdateAsync(
        DurableRequestRecord record,
        Func<DurableRequestRecord, DurableRequestRecord> transition,
        CancellationToken cancellationToken)
    {
        var path = GetRecordPath(record.Session, record.RequestId);

        await _gate.WaitAsync(cancellationToken);
        try
        {
            var current = await ReadRecordAsync(path, cancellationToken);
            EnsureSameIdentity(record, current);

            var updated = transition(current);
            if (updated == current)
            {
                return current;
            }

            await WriteAtomicAsync(path, updated, cancellationToken);
            return updated;
        }
        finally
        {
            _gate.Release();
        }
    }

    private DurableReservation CompareExisting(
        DurableRequestRecord existing,
        BridgeRequest request,
        string conversationKey,
        string fingerprint)
    {
        var same =
            string.Equals(existing.Schema, Schema, StringComparison.Ordinal) &&
            string.Equals(existing.Session, request.Session, StringComparison.Ordinal) &&
            string.Equals(existing.RequestId, request.Id, StringComparison.Ordinal) &&
            string.Equals(existing.Tool, request.Tool, StringComparison.Ordinal) &&
            string.Equals(existing.ConversationKey, conversationKey, StringComparison.Ordinal) &&
            string.Equals(existing.FingerprintSha256, fingerprint, StringComparison.Ordinal);

        return new DurableReservation(
            same ? DurableReservationStatus.Duplicate : DurableReservationStatus.Conflict,
            existing);
    }

    private static void EnsureSameIdentity(
        DurableRequestRecord expected,
        DurableRequestRecord actual)
    {
        if (!string.Equals(expected.Schema, actual.Schema, StringComparison.Ordinal) ||
            !string.Equals(expected.Session, actual.Session, StringComparison.Ordinal) ||
            !string.Equals(expected.RequestId, actual.RequestId, StringComparison.Ordinal) ||
            !string.Equals(expected.Tool, actual.Tool, StringComparison.Ordinal) ||
            !string.Equals(expected.ConversationKey, actual.ConversationKey, StringComparison.Ordinal) ||
            !string.Equals(expected.FingerprintSha256, actual.FingerprintSha256, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Durable ledger identity changed for request {expected.RequestId}.");
        }
    }

    private static void EnsurePendingPayload(DurableRequestRecord record)
    {
        if (string.IsNullOrEmpty(record.PendingResultMessage) ||
            string.IsNullOrWhiteSpace(record.PendingResultSha256) ||
            record.PendingResultBytes is null)
        {
            throw new InvalidOperationException(
                $"Durable pending result is incomplete for request {record.RequestId}.");
        }

        var bytes = Encoding.UTF8.GetBytes(record.PendingResultMessage);
        var sha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

        if (bytes.Length != record.PendingResultBytes.Value ||
            !string.Equals(sha256, record.PendingResultSha256, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                $"Durable pending result failed integrity validation for request {record.RequestId}.");
        }
    }

    private string GetRecordPath(string session, string requestId)
    {
        var keyBytes = Encoding.UTF8.GetBytes(session + "\n" + requestId);
        var key = Convert.ToHexString(SHA256.HashData(keyBytes)).ToLowerInvariant();
        return Path.Combine(_directory, key + ".json");
    }

    private static string ComputeFingerprint(BridgeRequest request)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            writer.WriteStartObject();
            writer.WriteString("tool", request.Tool);
            writer.WritePropertyName("args");
            WriteCanonicalJson(writer, request.Args);
            writer.WriteEndObject();
            writer.Flush();
        }

        return Convert.ToHexString(SHA256.HashData(stream.ToArray())).ToLowerInvariant();
    }

    private static void WriteCanonicalJson(Utf8JsonWriter writer, JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteCanonicalJson(writer, property.Value);
                }
                writer.WriteEndObject();
                break;

            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    WriteCanonicalJson(writer, item);
                }
                writer.WriteEndArray();
                break;

            case JsonValueKind.String:
                writer.WriteStringValue(element.GetString());
                break;

            case JsonValueKind.Number:
                writer.WriteRawValue(element.GetRawText(), skipInputValidation: false);
                break;

            case JsonValueKind.True:
                writer.WriteBooleanValue(true);
                break;

            case JsonValueKind.False:
                writer.WriteBooleanValue(false);
                break;

            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                writer.WriteNullValue();
                break;

            default:
                throw new InvalidOperationException($"Unsupported JSON value kind: {element.ValueKind}.");
        }
    }

    private async Task<DurableRequestRecord> ReadRecordAsync(
        string path,
        CancellationToken cancellationToken)
    {
        var json = await File.ReadAllTextAsync(path, cancellationToken);
        return JsonSerializer.Deserialize<DurableRequestRecord>(json, _jsonOptions)
               ?? throw new InvalidOperationException($"Durable ledger record is invalid: {path}");
    }

    private async Task WriteNewAsync(
        string path,
        DurableRequestRecord record,
        CancellationToken cancellationToken)
    {
        var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(record, _jsonOptions));

        await using var stream = new FileStream(
            path,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.Read,
            4096,
            FileOptions.Asynchronous | FileOptions.WriteThrough);

        await stream.WriteAsync(bytes, cancellationToken);
        await stream.FlushAsync(cancellationToken);
    }

    private async Task WriteAtomicAsync(
        string path,
        DurableRequestRecord record,
        CancellationToken cancellationToken)
    {
        var tempPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(record, _jsonOptions));

            await using (var stream = new FileStream(
                             tempPath,
                             FileMode.CreateNew,
                             FileAccess.Write,
                             FileShare.None,
                             4096,
                             FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(bytes, cancellationToken);
                await stream.FlushAsync(cancellationToken);
            }

            File.Move(tempPath, path, overwrite: true);
        }
        finally
        {
            if (File.Exists(tempPath))
            {
                File.Delete(tempPath);
            }
        }
    }
}
