using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static async Task ExpectInvalidOperationAsync(Func<Task> action, string message)
{
    try
    {
        await action();
    }
    catch (InvalidOperationException)
    {
        return;
    }

    throw new InvalidOperationException(message);
}

static JsonElement CreateRequestElement(
    string session,
    string id,
    string tool,
    string argsJson)
{
    using var argsDocument = JsonDocument.Parse(argsJson);
    var payload = JsonSerializer.Serialize(new
    {
        session,
        id,
        tool,
        args = argsDocument.RootElement.Clone()
    });

    using var requestDocument = JsonDocument.Parse(payload);
    return requestDocument.RootElement.Clone();
}

var root = Path.Combine(
    Path.GetTempPath(),
    "ChatGptDesktopLocalBridge-M3Smoke-" + Guid.NewGuid().ToString("N"));

Directory.CreateDirectory(root);

try
{
    var ledgerDirectory = Path.Combine(root, "ledger");
    var ledger = new BridgeExecutionLedger(ledgerDirectory);

    using var argsDocument = JsonDocument.Parse(
        """{"path":"C:/Windows/win.ini","max_chars":4096}""");

    var request = new BridgeRequest(
        "0123456789abcdef0123456789abcdef",
        "req-ledger",
        "fs.read_text",
        argsDocument.RootElement.Clone());

    var capability = BridgeCapabilityRegistry.Resolve(request.Tool);
    Assert(capability.Known, "fs.read_text must be a known capability.");
    Assert(
        capability.Semantics == BridgeExecutionSemantics.ReadOnly,
        "fs.read_text must remain read-only.");

    var record = ledger.CreateReceived(request, capability);
    await ledger.SaveAsync(record);

    var loaded = await ledger.GetAsync(request.Session, request.Id);
    Assert(loaded?.State == BridgeRequestState.Received, "Received state was not durable.");

    record = record with { State = BridgeRequestState.ExecutionStarted };
    await ledger.SaveAsync(record);

    var serialized = BridgeResultCodec.SerializeBounded(
        new BridgeResult(
            request.Session,
            request.Id,
            true,
            new { text = "ok" }),
        capability.MaxResultBytes);

    Assert(!serialized.WasBounded, "Small result was unexpectedly bounded.");

    record = record with
    {
        State = BridgeRequestState.ResultReady,
        ResultEnvelopeJson = serialized.Json,
        ExecutionOk = true,
        ElapsedMs = 12
    };
    await ledger.SaveAsync(record);

    record = record with { State = BridgeRequestState.DeliveryPending };
    await ledger.SaveAsync(record);

    record = record with { State = BridgeRequestState.Delivered };
    await ledger.SaveAsync(record);

    var reloadedLedger = new BridgeExecutionLedger(ledgerDirectory);
    loaded = await reloadedLedger.GetAsync(request.Session, request.Id);

    Assert(loaded?.State == BridgeRequestState.Delivered, "Delivered state did not survive ledger reopen.");
    Assert(
        !string.IsNullOrWhiteSpace(loaded.ResultEnvelopeJson),
        "Durable result envelope was lost.");

    await ExpectInvalidOperationAsync(
        () => reloadedLedger.SaveAsync(
            loaded with { State = BridgeRequestState.ExecutionStarted }),
        "Delivered request was allowed to regress to ExecutionStarted.");

    var oversized = BridgeResultCodec.SerializeBounded(
        new BridgeResult(
            request.Session,
            "req-large",
            true,
            new { text = new string('x', 16 * 1024) }),
        1024);

    Assert(oversized.WasBounded, "Oversized result was not bounded.");
    Assert(!oversized.Envelope.Ok, "Bounded oversized result must be an error envelope.");
    Assert(
        oversized.Envelope.Error?.Code == "result_too_large",
        "Oversized result did not produce result_too_large.");

    var unknown = BridgeCapabilityRegistry.Resolve("unknown.tool");
    Assert(!unknown.Known, "Unknown capability was marked known.");

    var policy = new PermissionPolicy
    {
        Capabilities = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["system.info"] = "AUTO"
        }
    };

    var hostLedgerDirectory = Path.Combine(root, "host-ledger");
    var hostLogDirectory = Path.Combine(root, "host-logs");
    var deliveredMessages = new List<string>();
    var statuses = new List<string>();

    var hostLedger = new BridgeExecutionLedger(hostLedgerDirectory);
    var host = new BridgeHost(
        policy,
        message =>
        {
            deliveredMessages.Add(message);
            return Task.FromResult(true);
        },
        statuses.Add,
        ledger: hostLedger,
        logDirectory: hostLogDirectory);

    var hostRequest = CreateRequestElement(
        host.SessionId,
        "req-once",
        "system.info",
        "{}");

    await host.HandleAsync(hostRequest);

    var hostRecord = await hostLedger.GetAsync(host.SessionId, "req-once");
    Assert(hostRecord?.State == BridgeRequestState.Delivered, "Successful host request was not marked Delivered.");
    Assert(deliveredMessages.Count == 1, "Successful host request did not emit exactly one result.");

    await host.HandleAsync(hostRequest);
    Assert(
        deliveredMessages.Count == 1,
        "Already delivered duplicate request emitted another result.");

    var failedDeliveryMessages = new List<string>();
    var failedLedger = new BridgeExecutionLedger(Path.Combine(root, "failed-ledger"));

    var failedHost = new BridgeHost(
        policy,
        message =>
        {
            failedDeliveryMessages.Add(message);
            return Task.FromResult(false);
        },
        statuses.Add,
        ledger: failedLedger,
        logDirectory: Path.Combine(root, "failed-logs"));

    var failedRequest = CreateRequestElement(
        failedHost.SessionId,
        "req-delivery",
        "system.info",
        "{}");

    await failedHost.HandleAsync(failedRequest);

    var failedRecord = await failedLedger.GetAsync(
        failedHost.SessionId,
        "req-delivery");

    Assert(
        failedRecord?.State == BridgeRequestState.DeliveryPending,
        "Unconfirmed delivery did not remain DeliveryPending.");
    Assert(
        !string.IsNullOrWhiteSpace(failedRecord.ResultEnvelopeJson),
        "Unconfirmed delivery lost its durable result.");
    Assert(
        failedDeliveryMessages.Count == 1,
        "Initial delivery attempt count is incorrect.");

    await failedHost.HandleAsync(failedRequest);

    failedRecord = await failedLedger.GetAsync(
        failedHost.SessionId,
        "req-delivery");

    Assert(
        failedRecord?.State == BridgeRequestState.DeliveryPending,
        "Duplicate request changed uncertain delivery state.");
    Assert(
        failedDeliveryMessages.Count == 2,
        "Duplicate uncertain delivery should emit only one transient safety error.");
    Assert(
        failedDeliveryMessages[1].Contains("delivery_state_uncertain", StringComparison.Ordinal),
        "Duplicate uncertain delivery did not return delivery_state_uncertain.");

    Console.WriteLine("BRIDGE-M3 durable foundation smoke: PASS");
}
finally
{
    try
    {
        Directory.Delete(root, recursive: true);
    }
    catch
    {
    }
}
