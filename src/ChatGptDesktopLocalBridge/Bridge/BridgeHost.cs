using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed class BridgeHost
{
    private const string RequestStart = "[[LOCAL_BRIDGE_REQUEST_V1]]";
    private const string RequestEnd = "[[/LOCAL_BRIDGE_REQUEST_V1]]";
    private const string ResultStart = "[[LOCAL_BRIDGE_RESULT_V1]]";
    private const string ResultEnd = "[[/LOCAL_BRIDGE_RESULT_V1]]";
    private const string BootstrapStart = "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]";
    private const string BootstrapEnd = "[[/LOCAL_BRIDGE_BOOTSTRAP_V1]]";
    public const int MaxResultMessageBytes = 256 * 1024;

    private readonly PermissionPolicy _policy;
    private readonly Func<string, Task<bool>> _sendToChat;
    private readonly Func<string?> _conversationKeyProvider;
    private readonly Action<string> _status;
    private readonly ToolRouter _router = new();
    private readonly DurableRequestLedger _requestLedger;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _logDirectory;

    public BridgeHost(
        PermissionPolicy policy,
        Func<string, Task<bool>> sendToChat,
        Func<string?> conversationKeyProvider,
        Action<string> status,
        string? sessionId = null)
    {
        _policy = policy;
        _sendToChat = sendToChat;
        _conversationKeyProvider = conversationKeyProvider;
        _status = status;
        SessionId = string.IsNullOrWhiteSpace(sessionId)
            ? Guid.NewGuid().ToString("N")
            : sessionId;

        var dataRoot = GetDataRoot();

        _logDirectory = Path.Combine(dataRoot, "logs");
        Directory.CreateDirectory(_logDirectory);

        _requestLedger = new DurableRequestLedger(GetLedgerDirectory(dataRoot));
    }

    public string SessionId { get; }

    public string ReadyMarker => $"[[LOCAL_BRIDGE_READY_V1:{SessionId}]]";

    public static async Task<IReadOnlyList<DurableRequestRecord>> FindRecoverableAsync(
        string conversationKey,
        CancellationToken cancellationToken = default)
    {
        var ledger = new DurableRequestLedger(GetLedgerDirectory(GetDataRoot()));
        return await ledger.FindRecoverableAsync(conversationKey, cancellationToken);
    }

    public string CreateBootstrapMessage()
    {
        return string.Join(
            Environment.NewLine,
            BootstrapStart,
            "You are running inside a custom Windows ChatGPT client with Local Bridge v1.",
            string.Empty,
            "Current bridge session:",
            SessionId,
            string.Empty,
            "When you need local-computer data, respond with EXACTLY ONE machine request and no human prose:",
            string.Empty,
            RequestStart,
            "{",
            $"  \"session\": \"{SessionId}\",",
            "  \"id\": \"req-<unique-id>\",",
            "  \"tool\": \"<tool-name>\",",
            "  \"args\": { }",
            "}",
            RequestEnd,
            string.Empty,
            "Available tools:",
            "1. system.info",
            "   args: {}",
            string.Empty,
            "2. fs.list",
            "   args: { \"path\": \"C:/some/directory\" }",
            string.Empty,
            "3. fs.read_text",
            "   args: { \"path\": \"C:/some/file.txt\", \"max_chars\": 200000 }",
            string.Empty,
            "Handshake:",
            "- Immediately after receiving this bootstrap, reply with EXACTLY this single line and no other text:",
            ReadyMarker,
            string.Empty,
            "Rules:",
            "- Use the bridge only when local data/action is needed.",
            "- Never invent a LOCAL_BRIDGE_RESULT.",
            "- In bridge JSON, write Windows paths with forward slashes, for example C:/Windows/win.ini. Do not use backslashes in JSON path strings.",
            "- One request per assistant turn.",
            "- Wait for LOCAL_BRIDGE_RESULT_V1 before continuing.",
            "- After a result, continue normally in the user's language.",
            "- Do not wrap a bridge request in Markdown fences.",
            "- The session value must exactly match the session above.",
            BootstrapEnd);
    }

    public async Task HandleAsync(JsonElement requestElement)
    {
        await _gate.WaitAsync();
        try
        {
            BridgeRequest? request;
            try
            {
                request = requestElement.Deserialize<BridgeRequest>(
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            }
            catch (Exception ex)
            {
                _status($"Rejected malformed bridge request: {ex.Message}");
                return;
            }

            if (request is null ||
                string.IsNullOrWhiteSpace(request.Id) ||
                string.IsNullOrWhiteSpace(request.Tool))
            {
                _status("Rejected malformed bridge request.");
                return;
            }

            if (!string.Equals(request.Session, SessionId, StringComparison.Ordinal))
            {
                _status("Rejected bridge request with an invalid session.");
                return;
            }

            var conversationKey = _conversationKeyProvider();
            if (string.IsNullOrWhiteSpace(conversationKey))
            {
                _status("Rejected bridge request because the current ChatGPT conversation cannot be bound durably.");
                await TrySendProtocolErrorAsync(
                    request,
                    "conversation_binding_unavailable",
                    "The current ChatGPT page has no stable conversation id. Open the conversation and retry.");
                return;
            }

            var reservation = await _requestLedger.ReserveAsync(request, conversationKey);

            if (reservation.Status == DurableReservationStatus.Conflict)
            {
                _status($"Rejected conflicting reuse of request id {request.Id}.");
                await TrySendProtocolErrorAsync(
                    request,
                    "request_id_conflict",
                    "The same session/request id was already reserved with a different conversation, tool, or argument payload.");
                return;
            }

            if (reservation.Status == DurableReservationStatus.Duplicate)
            {
                var existing = reservation.Record;
                _status(
                    $"Ignored durable duplicate request {request.Id}: " +
                    $"execution={existing.ExecutionState}, delivery={existing.DeliveryState}.");
                return;
            }

            var ledgerRecord = await _requestLedger.MarkExecutingAsync(reservation.Record);
            var capability = ToolRouter.GetCapability(request.Tool);
            var decision = _policy.GetDecision(capability);

            if (decision == PermissionDecision.Deny)
            {
                var envelope = new BridgeResult(
                    SessionId,
                    request.Id,
                    false,
                    Error: new BridgeError(
                        "permission_denied",
                        $"Capability {capability} is denied."));

                await CompleteAndDeliverAsync(
                    request,
                    ledgerRecord,
                    envelope,
                    false,
                    "permission_denied",
                    0,
                    $"{request.Tool} denied by permission policy.");
                return;
            }

            if (decision == PermissionDecision.Ask)
            {
                var envelope = new BridgeResult(
                    SessionId,
                    request.Id,
                    false,
                    Error: new BridgeError(
                        "permission_requires_confirmation",
                        $"Capability {capability} is configured as ASK. Interactive confirmation UI is the next implementation stage."));

                await CompleteAndDeliverAsync(
                    request,
                    ledgerRecord,
                    envelope,
                    false,
                    "permission_requires_confirmation",
                    0,
                    $"{request.Tool} requires interactive confirmation.");
                return;
            }

            var stopwatch = Stopwatch.StartNew();
            BridgeResult resultEnvelope;
            bool ok;
            string? errorCode;
            string deliveredStatus;

            try
            {
                _status($"Running {request.Tool} ({request.Id})…");
                var result = await _router.ExecuteAsync(request.Tool, request.Args);
                stopwatch.Stop();

                ok = true;
                errorCode = null;
                resultEnvelope = new BridgeResult(SessionId, request.Id, true, result);
                deliveredStatus =
                    $"{request.Tool} completed in {stopwatch.ElapsedMilliseconds} ms.";
            }
            catch (BridgeToolException ex)
            {
                stopwatch.Stop();

                ok = false;
                errorCode = ex.Code;
                resultEnvelope = new BridgeResult(
                    SessionId,
                    request.Id,
                    false,
                    Error: new BridgeError(ex.Code, ex.Message));
                deliveredStatus = $"{request.Tool} failed: {ex.Message}";
            }
            catch (Exception ex)
            {
                stopwatch.Stop();

                ok = false;
                errorCode = "tool_error";
                resultEnvelope = new BridgeResult(
                    SessionId,
                    request.Id,
                    false,
                    Error: new BridgeError("tool_error", ex.Message));
                deliveredStatus = $"{request.Tool} failed: {ex.Message}";
            }

            await CompleteAndDeliverAsync(
                request,
                ledgerRecord,
                resultEnvelope,
                ok,
                errorCode,
                stopwatch.ElapsedMilliseconds,
                deliveredStatus);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<bool> RecoverPendingAsync(
        DurableRequestRecord record,
        Func<string, string, Task<bool>> resultAlreadyPresent)
    {
        await _gate.WaitAsync();
        try
        {
            var conversationKey = _conversationKeyProvider();
            if (string.IsNullOrWhiteSpace(conversationKey) ||
                !string.Equals(conversationKey, record.ConversationKey, StringComparison.Ordinal) ||
                !string.Equals(SessionId, record.Session, StringComparison.Ordinal))
            {
                _status("Pending bridge result recovery was blocked by conversation/session mismatch.");
                return false;
            }

            DurableRequestLedger.ValidatePendingPayload(record);

            var current = record;
            if (current.DeliveryState == DurableDeliveryState.Sending)
            {
                bool present;
                try
                {
                    present = await resultAlreadyPresent(current.Session, current.RequestId);
                }
                catch (Exception ex)
                {
                    _status($"Could not reconcile pending bridge result {current.RequestId}: {ex.Message}");
                    return false;
                }

                if (present)
                {
                    await _requestLedger.MarkDeliveredAsync(current);
                    _status($"Recovered delivered bridge result {current.RequestId} without replay.");
                    return true;
                }
            }
            else if (current.DeliveryState == DurableDeliveryState.Pending)
            {
                current = await _requestLedger.MarkSendingAsync(current);
            }
            else
            {
                _status($"Bridge result {current.RequestId} is not recoverable from state {current.DeliveryState}.");
                return false;
            }

            var sent = await _sendToChat(current.PendingResultMessage!);
            if (!sent)
            {
                _status($"Bridge result {current.RequestId} remains pending delivery.");
                return false;
            }

            await _requestLedger.MarkDeliveredAsync(current);
            _status($"Recovered pending bridge result {current.RequestId}.");
            return true;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task CompleteAndDeliverAsync(
        BridgeRequest request,
        DurableRequestRecord ledgerRecord,
        BridgeResult requestedResult,
        bool requestedOk,
        string? requestedErrorCode,
        long elapsedMs,
        string deliveredStatus)
    {
        var bounded = BuildBoundedResult(request, requestedResult, requestedOk, requestedErrorCode);
        var completed = await _requestLedger.MarkCompletedAsync(
            ledgerRecord,
            bounded.Ok,
            bounded.ErrorCode,
            elapsedMs,
            bounded.Message);

        try
        {
            await WriteAuditAsync(request, bounded.Ok, bounded.ErrorCode, elapsedMs);
        }
        catch (Exception ex)
        {
            _status($"Audit write failed for {request.Id}: {ex.Message}");
        }

        var sending = await _requestLedger.MarkSendingAsync(completed);

        try
        {
            var sent = await _sendToChat(sending.PendingResultMessage!);
            if (!sent)
            {
                _status(
                    $"{request.Tool} completed locally, but result delivery is pending recovery.");
                return;
            }
        }
        catch (Exception ex)
        {
            _status(
                $"{request.Tool} completed locally, but result delivery is pending recovery: {ex.Message}");
            return;
        }

        try
        {
            await _requestLedger.MarkDeliveredAsync(sending);
        }
        catch (Exception ex)
        {
            _status(
                $"{request.Tool} result was sent, but durable delivery commit is uncertain: {ex.Message}");
            return;
        }

        _status(bounded.WasTruncatedToError
            ? $"{request.Tool} completed, but its result exceeded the {MaxResultMessageBytes} byte bridge transport limit."
            : deliveredStatus);
    }

    private BoundedResult BuildBoundedResult(
        BridgeRequest request,
        BridgeResult requestedResult,
        bool requestedOk,
        string? requestedErrorCode)
    {
        var message = SerializeResultMessage(requestedResult);
        if (Encoding.UTF8.GetByteCount(message) <= MaxResultMessageBytes)
        {
            return new BoundedResult(
                requestedOk,
                requestedErrorCode,
                message,
                false);
        }

        var errorCode = "result_too_large_after_execution";
        var boundedEnvelope = new BridgeResult(
            SessionId,
            request.Id,
            false,
            Error: new BridgeError(
                errorCode,
                $"The local tool completed, but its serialized result exceeded the {MaxResultMessageBytes} byte bridge transport limit. Retry with a smaller requested result."));

        var boundedMessage = SerializeResultMessage(boundedEnvelope);
        return new BoundedResult(false, errorCode, boundedMessage, true);
    }

    private async Task TrySendProtocolErrorAsync(
        BridgeRequest request,
        string code,
        string message)
    {
        try
        {
            var envelope = new BridgeResult(
                SessionId,
                request.Id,
                false,
                Error: new BridgeError(code, message));

            await _sendToChat(SerializeResultMessage(envelope));
        }
        catch (Exception ex)
        {
            _status($"Could not deliver protocol error for {request.Id}: {ex.Message}");
        }
    }

    private static string SerializeResultMessage(BridgeResult result)
    {
        var json = JsonSerializer.Serialize(result, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
        });

        return $"{ResultStart}\n{json}\n{ResultEnd}";
    }

    private async Task WriteAuditAsync(
        BridgeRequest request,
        bool ok,
        string? errorCode,
        long elapsedMs)
    {
        var record = new
        {
            timestampUtc = DateTimeOffset.UtcNow,
            session = SessionId,
            requestId = request.Id,
            tool = request.Tool,
            ok,
            errorCode,
            elapsedMs
        };

        var path = Path.Combine(
            _logDirectory,
            $"bridge-{DateTime.UtcNow:yyyyMMdd}.jsonl");

        await File.AppendAllTextAsync(path, JsonSerializer.Serialize(record) + Environment.NewLine);
    }

    private static string GetDataRoot()
        => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge");

    private static string GetLedgerDirectory(string dataRoot)
        => Path.Combine(dataRoot, "state", "requests");

    private sealed record BoundedResult(
        bool Ok,
        string? ErrorCode,
        string Message,
        bool WasTruncatedToError);
}
