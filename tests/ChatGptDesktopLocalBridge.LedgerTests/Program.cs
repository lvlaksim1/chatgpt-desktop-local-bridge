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
    var conversation = "chatgpt:conversation:11111111-2222-3333-4444-555555555555";
    var session = "0123456789abcdef0123456789abcdef";
    var request = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"path\":\"C:/Windows/win.ini\",\"max_chars\":4096}"));

    var parsedConversation = BridgeConversationIdentity.TryGetConversationKey(
        new Uri("https://chatgpt.com/c/11111111-2222-3333-4444-555555555555?temporary-chat=false"));
    Require(parsedConversation == conversation, "Conversation identity normalization changed.");
    Require(
        BridgeConversationIdentity.TryGetConversationKey(new Uri("https://chatgpt.com/")) is null,
        "Home page must not be treated as a durable conversation.");

    var ledger = new DurableRequestLedger(root);

    var first = await ledger.ReserveAsync(request, conversation);
    Require(first.Status == DurableReservationStatus.Created, "First reservation was not created.");
    Require(first.Record.ExecutionState == DurableExecutionState.Reserved, "First reservation state is not reserved.");
    Require(first.Record.DeliveryState == DurableDeliveryState.NotReady, "Initial delivery state is not notReady.");
    Require(first.Record.ConversationKey == conversation, "Conversation binding was not persisted.");

    var executing = await ledger.MarkExecutingAsync(first.Record);
    Require(executing.ExecutionState == DurableExecutionState.Executing, "Executing state was not persisted.");

    var afterRestart = new DurableRequestLedger(root);
    var replayWhileExecuting = await afterRestart.ReserveAsync(request, conversation);
    Require(replayWhileExecuting.Status == DurableReservationStatus.Duplicate, "Replay after restart was not detected.");
    Require(replayWhileExecuting.Record.ExecutionState == DurableExecutionState.Executing,
        "Replay did not recover the executing state.");

    var pendingMessage =
        "[[LOCAL_BRIDGE_RESULT_V1]]\n" +
        "{\"session\":\"0123456789abcdef0123456789abcdef\",\"request_id\":\"req-durable-001\",\"ok\":true,\"result\":{\"text\":\"ok\"}}\n" +
        "[[/LOCAL_BRIDGE_RESULT_V1]]";

    var completed = await afterRestart.MarkCompletedAsync(
        replayWhileExecuting.Record,
        ok: true,
        errorCode: null,
        elapsedMs: 37,
        pendingResultMessage: pendingMessage);

    Require(completed.ExecutionState == DurableExecutionState.Completed, "Completed state was not persisted.");
    Require(completed.DeliveryState == DurableDeliveryState.Pending, "Completion did not create pending delivery.");
    Require(completed.PendingResultMessage == pendingMessage, "Pending result payload was not persisted atomically.");
    Require(completed.PendingResultBytes > 0, "Pending result byte length was not recorded.");

    var equivalentRequest = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"max_chars\":4096,\"path\":\"C:/Windows/win.ini\"}"));

    var secondRestart = new DurableRequestLedger(root);
    var replayPending = await secondRestart.ReserveAsync(equivalentRequest, conversation);
    Require(replayPending.Status == DurableReservationStatus.Duplicate,
        "Canonical equivalent request was not recognized as the same durable request.");
    Require(replayPending.Record.DeliveryState == DurableDeliveryState.Pending,
        "Pending delivery state did not survive restart.");

    var recoverable = await secondRestart.FindRecoverableAsync(conversation);
    Require(recoverable.Count == 1, "Pending result was not discoverable for the bound conversation.");
    Require(recoverable[0].PendingResultMessage == pendingMessage,
        "Recovered pending result payload changed.");

    var sending = await secondRestart.MarkSendingAsync(replayPending.Record);
    Require(sending.DeliveryState == DurableDeliveryState.Sending, "Sending state was not persisted.");

    var thirdRestart = new DurableRequestLedger(root);
    var recoverSending = await thirdRestart.FindRecoverableAsync(conversation);
    Require(recoverSending.Count == 1 && recoverSending[0].DeliveryState == DurableDeliveryState.Sending,
        "Uncertain sending state did not survive restart.");

    var delivered = await thirdRestart.MarkDeliveredAsync(recoverSending[0]);
    Require(delivered.DeliveryState == DurableDeliveryState.Delivered, "Delivered state was not persisted.");
    Require(delivered.PendingResultMessage is null, "Delivered payload was not retired.");

    var fourthRestart = new DurableRequestLedger(root);
    var replayDelivered = await fourthRestart.ReserveAsync(request, conversation);
    Require(replayDelivered.Status == DurableReservationStatus.Duplicate,
        "Delivered request replay was not detected.");
    Require(replayDelivered.Record.DeliveryState == DurableDeliveryState.Delivered,
        "Delivered state did not survive restart.");
    Require((await fourthRestart.FindRecoverableAsync(conversation)).Count == 0,
        "Delivered request remained recoverable.");

    var conflictingRequest = new BridgeRequest(
        session,
        "req-durable-001",
        "fs.read_text",
        Args("{\"path\":\"C:/Windows/win.ini\",\"max_chars\":8192}"));

    var conflict = await fourthRestart.ReserveAsync(conflictingRequest, conversation);
    Require(conflict.Status == DurableReservationStatus.Conflict,
        "Conflicting reuse of a durable request id was not rejected.");

    var conversationConflict = await fourthRestart.ReserveAsync(
        request,
        "chatgpt:conversation:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee");
    Require(conversationConflict.Status == DurableReservationStatus.Conflict,
        "Cross-conversation reuse of a durable request id was not rejected.");

    Console.WriteLine("durable request ledger regression: PASS");
}
finally
{
    if (Directory.Exists(root))
    {
        Directory.Delete(root, recursive: true);
    }
}
