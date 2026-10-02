using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;

static void Require(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException(message);
    }
}

static JsonElement Args(string json)
{
    using var document = JsonDocument.Parse(json);
    return document.RootElement.Clone();
}

var root = Path.Combine(
    Path.GetTempPath(),
    "chatgpt-local-bridge-ledger-test-" + Guid.NewGuid().ToString("N"));

try
{
    var session = "0123456789abcdef0123456789abcdef";
    var request = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"path\":\"C:/Windows/win.ini\",\"max_chars\":4096}"));

    var ledger = new DurableRequestLedger(root);

    var first = await ledger.ReserveAsync(request);
    Require(first.Status == DurableReservationStatus.Created, "First reservation was not created.");
    Require(first.Record.ExecutionState == DurableExecutionState.Reserved, "First reservation state is not reserved.");
    Require(first.Record.DeliveryState == DurableDeliveryState.NotReady, "Initial delivery state is not notReady.");

    var executing = await ledger.MarkExecutingAsync(first.Record);
    Require(executing.ExecutionState == DurableExecutionState.Executing, "Executing state was not persisted.");

    var afterRestart = new DurableRequestLedger(root);
    var replayWhileExecuting = await afterRestart.ReserveAsync(request);
    Require(replayWhileExecuting.Status == DurableReservationStatus.Duplicate, "Replay after restart was not detected.");
    Require(replayWhileExecuting.Record.ExecutionState == DurableExecutionState.Executing,
        "Replay did not recover the executing state.");

    var resultEnvelopeJson =
        "{\"session\":\"0123456789abcdef0123456789abcdef\",\"request_id\":\"req-durable-001\",\"ok\":true,\"result\":{\"text\":\"ok\"}}";

    var completed = await afterRestart.MarkCompletedAsync(
        replayWhileExecuting.Record,
        ok: true,
        errorCode: null,
        elapsedMs: 37,
        resultEnvelopeJson: resultEnvelopeJson);

    Require(completed.ExecutionState == DurableExecutionState.Completed, "Completed state was not persisted.");
    Require(completed.DeliveryState == DurableDeliveryState.Pending, "Completion did not create pending delivery.");
    Require(completed.ResultEnvelopeJson == resultEnvelopeJson, "Completed request did not persist its result envelope.");

    var equivalentRequest = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"max_chars\":4096,\"path\":\"C:/Windows/win.ini\"}"));

    var secondRestart = new DurableRequestLedger(root);
    var replayPending = await secondRestart.ReserveAsync(equivalentRequest);
    Require(replayPending.Status == DurableReservationStatus.Duplicate,
        "Canonical equivalent request was not recognized as the same durable request.");
    Require(replayPending.Record.DeliveryState == DurableDeliveryState.Pending,
        "Pending delivery state did not survive restart.");
    Require(replayPending.Record.ResultEnvelopeJson == resultEnvelopeJson,
        "Pending result payload did not survive restart.");

    var pendingDeliveries = await secondRestart.GetPendingDeliveriesAsync();
    Require(pendingDeliveries.Count == 1, "Pending delivery enumeration did not return exactly one record.");
    Require(pendingDeliveries[0].RequestId == request.Id, "Pending delivery enumeration returned the wrong request.");
    Require(pendingDeliveries[0].ResultEnvelopeJson == resultEnvelopeJson,
        "Pending delivery enumeration lost the persisted result payload.");

    var delivered = await secondRestart.MarkDeliveredAsync(replayPending.Record);
    Require(delivered.DeliveryState == DurableDeliveryState.Delivered, "Delivered state was not persisted.");

    var thirdRestart = new DurableRequestLedger(root);
    var replayDelivered = await thirdRestart.ReserveAsync(request);
    Require(replayDelivered.Status == DurableReservationStatus.Duplicate,
        "Delivered request replay was not detected.");
    Require(replayDelivered.Record.DeliveryState == DurableDeliveryState.Delivered,
        "Delivered state did not survive restart.");
    Require(replayDelivered.Record.ResultEnvelopeJson == resultEnvelopeJson,
        "Delivered record lost the persisted result payload.");

    var noPendingDeliveries = await thirdRestart.GetPendingDeliveriesAsync();
    Require(noPendingDeliveries.Count == 0, "Delivered result remained in the pending-delivery set.");

    var conflictingRequest = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"path\":\"C:/Windows/win.ini\",\"max_chars\":8192}"));

    var conflict = await thirdRestart.ReserveAsync(conflictingRequest);
    Require(conflict.Status == DurableReservationStatus.Conflict,
        "Conflicting reuse of a durable request id was not rejected.");

    Console.WriteLine("durable request ledger regression: PASS");
}
finally
{
    if (Directory.Exists(root))
    {
        Directory.Delete(root, recursive: true);
    }
}
