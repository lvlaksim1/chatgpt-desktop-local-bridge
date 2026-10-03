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
    Delivered
}

public enum DurableReservationStatus
{
    Created,
    Duplicate,
    Conflict
}

public enum DurableReplayAction
{
    ResumeReserved,
    BlockExecutionUncertain,
    RedeliverResult,
    IgnoreDelivered,
    BlockMissingResult
}

public sealed record DurableRequestRecord(
    string Schema,
    string Session,
    string RequestId,
    string Tool,
    string FingerprintSha256,
    DurableExecutionState ExecutionState,
    DurableDeliveryState DeliveryState,
    DateTimeOffset CreatedUtc,
    DateTimeOffset UpdatedUtc,
    bool? Ok = null,
    string? ErrorCode = null,
    long? ElapsedMs = null,
    string? ResultEnvelopeJson = null,
    string? ConversationUri = null);

public sealed record DurableReservation(
    DurableReservationStatus Status,
    DurableRequestRecord Record);

public sealed class DurableRequestLedger
{
    public const string Schema = "local-bridge-request-ledger-v1";

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

    public Task<DurableReservation> ReserveAsync(
        BridgeRequest request,
        CancellationToken cancellationToken = default)
        => ReserveAsync(request, conversationUri: null, cancellationToken);

    public async Task<DurableReservation> ReserveAsync(
        BridgeRequest request,
        string? conversationUri,
        CancellationToken cancellationToken = default)
    {
        var path = GetRecordPath(request.Session, request.Id);
        var fingerprint = ComputeFingerprint(request);
        var normalizedConversationUri = NormalizeConversationUri(conversationUri);

        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (File.Exists(path))
            {
                return CompareExisting(
                    await ReadRecordAsync(path, cancellationToken),
                    request,
                    fingerprint,
                    normalizedConversationUri);
            }

            var now = DateTimeOffset.UtcNow;
            var record = new DurableRequestRecord(
                Schema,
                request.Session,
                request.Id,
                request.Tool,
                fingerprint,
                DurableExecutionState.Reserved,
                DurableDeliveryState.NotReady,
                now,
                now,
                ConversationUri: normalizedConversationUri);

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
                    fingerprint,
                    normalizedConversationUri);
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

    public async Task<DurableRequestRecord> MarkCompletedAsync(
        DurableRequestRecord record,
        bool ok,
        string? errorCode,
        long elapsedMs,
        string resultEnvelopeJson,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(resultEnvelopeJson))
        {
            throw new ArgumentException("Result envelope JSON must not be empty.", nameof(resultEnvelopeJson));
        }

        using (JsonDocument.Parse(resultEnvelopeJson))
        {
        }

        return await UpdateAsync(
            record,
            current =>
            {
                if (current.ExecutionState == DurableExecutionState.Completed)
                {
                    if (current.Ok == ok &&
                        string.Equals(current.ErrorCode, errorCode, StringComparison.Ordinal) &&
                        current.ElapsedMs == elapsedMs &&
                        string.Equals(current.ResultEnvelopeJson, resultEnvelopeJson, StringComparison.Ordinal))
                    {
                        return current;
                    }

                    throw new InvalidOperationException(
                        $"Request {current.RequestId} is already completed with a different outcome.");
                }

                return current with
                {
                    ExecutionState = DurableExecutionState.Completed,
                    DeliveryState = DurableDeliveryState.Pending,
                    Ok = ok,
                    ErrorCode = errorCode,
                    ElapsedMs = elapsedMs,
                    ResultEnvelopeJson = resultEnvelopeJson,
                    UpdatedUtc = DateTimeOffset.UtcNow
                };
            },
            cancellationToken);
    }

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

                if (current.DeliveryState != DurableDeliveryState.Pending)
                {
                    throw new InvalidOperationException(
                        $"Cannot transition request {current.RequestId} from delivery state {current.DeliveryState} to delivered.");
                }

                return current with
                {
                    DeliveryState = DurableDeliveryState.Delivered,
                    ResultEnvelopeJson = null,
                    UpdatedUtc = DateTimeOffset.UtcNow
                };
            },
            cancellationToken);

    public static DurableReplayAction GetReplayAction(DurableRequestRecord record)
        => record.ExecutionState switch
        {
            DurableExecutionState.Reserved => DurableReplayAction.ResumeReserved,
            DurableExecutionState.Executing => DurableReplayAction.BlockExecutionUncertain,
            DurableExecutionState.Completed when record.DeliveryState == DurableDeliveryState.Delivered
                => DurableReplayAction.IgnoreDelivered,
            DurableExecutionState.Completed when string.IsNullOrWhiteSpace(record.ResultEnvelopeJson)
                => DurableReplayAction.BlockMissingResult,
            DurableExecutionState.Completed => DurableReplayAction.RedeliverResult,
            _ => throw new InvalidOperationException(
                $"Unknown durable execution state for request {record.RequestId}: {record.ExecutionState}.")
        };

    public Task<IReadOnlyList<DurableRequestRecord>> GetPendingDeliveriesAsync(
        CancellationToken cancellationToken = default)
        => GetPendingDeliveriesAsync(conversationUri: null, session: null, cancellationToken);

    public async Task<IReadOnlyList<DurableRequestRecord>> GetPendingDeliveriesAsync(
        string? conversationUri,
        string? session = null,
        CancellationToken cancellationToken = default)
    {
        var normalizedConversationUri = NormalizeConversationUri(conversationUri);

        await _gate.WaitAsync(cancellationToken);
        try
        {
            var records = new List<DurableRequestRecord>();

            foreach (var path in Directory.EnumerateFiles(_directory, "*.json")
                         .OrderBy(path => path, StringComparer.Ordinal))
            {
                var record = await ReadRecordAsync(path, cancellationToken);

                if (!string.Equals(record.Schema, Schema, StringComparison.Ordinal) ||
                    record.ExecutionState != DurableExecutionState.Completed ||
                    record.DeliveryState != DurableDeliveryState.Pending ||
                    string.IsNullOrWhiteSpace(record.ResultEnvelopeJson))
                {
                    continue;
                }

                if (normalizedConversationUri is not null &&
                    !string.Equals(record.ConversationUri, normalizedConversationUri, StringComparison.Ordinal))
                {
                    continue;
                }

                if (session is not null &&
                    !string.Equals(record.Session, session, StringComparison.Ordinal))
                {
                    continue;
                }

                records.Add(record);
            }

            return records
                .OrderBy(record => record.CreatedUtc)
                .ThenBy(record => record.RequestId, StringComparer.Ordinal)
                .ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

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
            if (ReferenceEquals(updated, current) || updated == current)
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
        string fingerprint,
        string? conversationUri)
    {
        var conversationMatches =
            existing.ConversationUri is null ||
            conversationUri is null ||
            string.Equals(existing.ConversationUri, conversationUri, StringComparison.Ordinal);

        var same =
            string.Equals(existing.Schema, Schema, StringComparison.Ordinal) &&
            string.Equals(existing.Session, request.Session, StringComparison.Ordinal) &&
            string.Equals(existing.RequestId, request.Id, StringComparison.Ordinal) &&
            string.Equals(existing.Tool, request.Tool, StringComparison.Ordinal) &&
            string.Equals(existing.FingerprintSha256, fingerprint, StringComparison.Ordinal) &&
            conversationMatches;

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
            !string.Equals(expected.FingerprintSha256, actual.FingerprintSha256, StringComparison.Ordinal) ||
            (expected.ConversationUri is not null &&
             actual.ConversationUri is not null &&
             !string.Equals(expected.ConversationUri, actual.ConversationUri, StringComparison.Ordinal)))
        {
            throw new InvalidOperationException(
                $"Durable ledger identity changed for request {expected.RequestId}.");
        }
    }

    public static string? NormalizeConversationUri(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) ||
            !Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return null;
        }

        var path = uri.AbsolutePath.TrimEnd('/');
        if (string.IsNullOrEmpty(path))
        {
            path = "/";
        }

        var builder = new UriBuilder(uri)
        {
            Query = string.Empty,
            Fragment = string.Empty,
            Path = path
        };

        return builder.Uri.GetLeftPart(UriPartial.Path).TrimEnd('/');
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