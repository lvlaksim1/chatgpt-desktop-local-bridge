using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public enum BridgeRequestState
{
    Received,
    ExecutionStarted,
    ResultReady,
    DeliveryPending,
    Delivered
}

public sealed record BridgeLedgerRecord(
    int SchemaVersion,
    string Session,
    string RequestId,
    string RequestFingerprint,
    string Tool,
    string Capability,
    BridgeRequestState State,
    DateTimeOffset CreatedUtc,
    DateTimeOffset UpdatedUtc,
    string? ResultEnvelopeJson = null,
    bool? ExecutionOk = null,
    string? ErrorCode = null,
    long? ElapsedMs = null);

public sealed class BridgeExecutionLedger
{
    public const int CurrentSchemaVersion = 1;

    private readonly string _rootDirectory;
    private readonly SemaphoreSlim _ioGate = new(1, 1);
    private readonly JsonSerializerOptions _jsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };

    public BridgeExecutionLedger(string? rootDirectory = null)
    {
        _rootDirectory = rootDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "ledger",
            "requests");

        Directory.CreateDirectory(_rootDirectory);
    }

    public string RootDirectory => _rootDirectory;

    public static string ComputeRequestFingerprint(BridgeRequest request)
    {
        var material = request.Tool + "\n" + request.Args.GetRawText();
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(material));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public BridgeLedgerRecord CreateReceived(
        BridgeRequest request,
        BridgeCapabilityDefinition capability)
    {
        var now = DateTimeOffset.UtcNow;
        return new BridgeLedgerRecord(
            CurrentSchemaVersion,
            request.Session,
            request.Id,
            ComputeRequestFingerprint(request),
            request.Tool,
            capability.Capability,
            BridgeRequestState.Received,
            now,
            now);
    }

    public async Task<BridgeLedgerRecord?> GetAsync(
        string session,
        string requestId)
    {
        await _ioGate.WaitAsync();
        try
        {
            return await ReadRecordAsync(GetRecordPath(session, requestId));
        }
        finally
        {
            _ioGate.Release();
        }
    }

    public async Task SaveAsync(BridgeLedgerRecord record)
    {
        await _ioGate.WaitAsync();
        try
        {
            if (record.SchemaVersion != CurrentSchemaVersion)
            {
                throw new InvalidOperationException(
                    $"Unsupported bridge ledger schema version {record.SchemaVersion}.");
            }

            var path = GetRecordPath(record.Session, record.RequestId);
            var existing = await ReadRecordAsync(path);

            if (existing is null)
            {
                if (record.State != BridgeRequestState.Received)
                {
                    throw new InvalidOperationException(
                        $"New bridge ledger record must start at {BridgeRequestState.Received}.");
                }
            }
            else
            {
                ValidateIdentity(existing, record);

                if (!IsAllowedTransition(existing.State, record.State))
                {
                    throw new InvalidOperationException(
                        $"Invalid bridge request state transition {existing.State} -> {record.State}.");
                }
            }

            var normalized = record with { UpdatedUtc = DateTimeOffset.UtcNow };
            var json = JsonSerializer.Serialize(normalized, _jsonOptions);
            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";

            try
            {
                await File.WriteAllTextAsync(temp, json, Encoding.UTF8);
                File.Move(temp, path, overwrite: true);
            }
            finally
            {
                if (File.Exists(temp))
                {
                    File.Delete(temp);
                }
            }
        }
        finally
        {
            _ioGate.Release();
        }
    }

    private string GetRecordPath(string session, string requestId)
    {
        var material = session + "\n" + requestId;
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(material));
        var fileName = Convert.ToHexString(hash).ToLowerInvariant() + ".json";
        return Path.Combine(_rootDirectory, fileName);
    }

    private async Task<BridgeLedgerRecord?> ReadRecordAsync(string path)
    {
        if (!File.Exists(path))
        {
            return null;
        }

        var json = await File.ReadAllTextAsync(path, Encoding.UTF8);
        return JsonSerializer.Deserialize<BridgeLedgerRecord>(
                   json,
                   new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
               ?? throw new InvalidOperationException(
                   $"Bridge ledger record is invalid: {path}");
    }

    private static void ValidateIdentity(
        BridgeLedgerRecord existing,
        BridgeLedgerRecord next)
    {
        if (!string.Equals(existing.Session, next.Session, StringComparison.Ordinal) ||
            !string.Equals(existing.RequestId, next.RequestId, StringComparison.Ordinal) ||
            !string.Equals(existing.RequestFingerprint, next.RequestFingerprint, StringComparison.Ordinal) ||
            !string.Equals(existing.Tool, next.Tool, StringComparison.Ordinal) ||
            !string.Equals(existing.Capability, next.Capability, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Bridge ledger identity fields are immutable.");
        }
    }

    private static bool IsAllowedTransition(
        BridgeRequestState from,
        BridgeRequestState to)
    {
        if (from == to)
        {
            return true;
        }

        return from switch
        {
            BridgeRequestState.Received =>
                to is BridgeRequestState.ExecutionStarted or BridgeRequestState.ResultReady,

            BridgeRequestState.ExecutionStarted =>
                to == BridgeRequestState.ResultReady,

            BridgeRequestState.ResultReady =>
                to == BridgeRequestState.DeliveryPending,

            BridgeRequestState.DeliveryPending =>
                to == BridgeRequestState.Delivered,

            BridgeRequestState.Delivered => false,
            _ => false
        };
    }
}
