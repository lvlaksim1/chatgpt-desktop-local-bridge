using System.Diagnostics;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed class BridgeHost
{
    private const string RequestStart = "[[LOCAL_BRIDGE_REQUEST_V1]]";
    private const string RequestEnd = "[[/LOCAL_BRIDGE_REQUEST_V1]]";
    private const string BootstrapStart = "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]";
    private const string BootstrapEnd = "[[/LOCAL_BRIDGE_BOOTSTRAP_V1]]";

    private readonly PermissionPolicy _policy;
    private readonly Func<string, Task<bool>> _sendToChat;
    private readonly Action<string> _status;
    private readonly ToolRouter _router = new();
    private readonly DurableRequestLedger _requestLedger;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _logDirectory;

    public BridgeHost(
        PermissionPolicy policy,
        Func<string, Task<bool>> sendToChat,
        Action<string> status,
        string? sessionId = null)
    {
        _policy = policy;
        _sendToChat = sendToChat;
        _status = status;

        if (sessionId is not null && !IsValidSessionId(sessionId))
        {
            throw new ArgumentException("Bridge session id must be exactly 32 hexadecimal characters.", nameof(sessionId));
        }

        SessionId = sessionId ?? Guid.NewGuid().ToString("N");

        var dataRoot = GetDataRoot();
        _logDirectory = Path.Combine(dataRoot, "logs");
        Directory.CreateDirectory(_logDirectory);

        _requestLedger = new DurableRequestLedger(GetRequestLedgerPath());
    }

    public string SessionId { get; }

    public string ReadyMarker => $"[[LOCAL_BRIDGE_READY_V1:{SessionId}]]";

    public static async Task<IReadOnlyList<DurableRequestRecord>> GetPendingDeliveriesForConversationAsync(
        string? conversationUri,
        CancellationToken cancellationToken = default)
    {
        var normalized = DurableRequestLedger.NormalizeConversationUri(conversationUri);
        if (normalized is null)
        {
            return Array.Empty<DurableRequestRecord>();
        }

        var ledger = new DurableRequestLedger(GetRequestLedgerPath());
        return await ledger.GetPendingDeliveriesAsync(normalized, session: null, cancellationToken);
    }

    public async Task RecoverPendingDeliveryAsync(
        DurableRequestRecord record,
        bool resultAlreadyVisible,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            if (!string.Equals(record.Session, SessionId, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("Pending result session does not match the active bridge session.");
            }

            if (record.ExecutionState != DurableExecutionState.Completed ||
                record.DeliveryState != DurableDeliveryState.Pending ||
                string.IsNullOrWhiteSpace(record.ResultEnvelopeJson))
            {
                throw new InvalidOperationException("Durable record is not a recoverable pending result.");
            }

            if (!resultAlreadyVisible)
            {
                await SendSerializedResultAsync(record.ResultEnvelopeJson);
            }

            await _requestLedger.MarkDeliveredAsync(record);

            _status(
                resultAlreadyVisible
                    ? $"Recovered delivery state for {record.RequestId}; result was already present in this conversation."
                    : $"Recovered pending result delivery for {record.RequestId} without re-executing {record.Tool}.");
        }
        finally
        {
            _gate.Release();
        }
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

    public async Task HandleAsync(
        JsonElement requestElement,
        string? conversationUri = null)
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

            var reservation = await _requestLedger.ReserveAsync(request, conversationUri);

            if (reservation.Status == DurableReservationStatus.Conflict)
            {
                _status($"Rejected conflicting reuse of request id {request.Id}.");
                await TrySendProtocolErrorAsync(
                    request,
                    "request_id_conflict",
                    "The same session/request id was already reserved with a different tool or argument payload.");
                return;
            }

            var ledgerRecord = reservation.Record;

            if (reservation.Status == DurableReservationStatus.Duplicate)
            {
                var replayAction = DurableRequestLedger.GetReplayAction(ledgerRecord);

                switch (replayAction)
                {
                    case DurableReplayAction.ResumeReserved:
                        _status($"Resuming reserved durable request {request.Id}.");
                        break;

                    case DurableReplayAction.BlockExecutionUncertain:
                        _status($"Refusing automatic replay of executing request {request.Id}.");
                        await TrySendProtocolErrorAsync(
                            request,
                            "request_execution_uncertain",
                            "The previous local execution reached executing state before interruption. Automatic replay is blocked.");
                        return;

                    case DurableReplayAction.BlockMissingResult:
                        _status($"Cannot recover completed request {request.Id}: durable result payload is missing.");
                        await TrySendProtocolErrorAsync(
                            request,
                            "result_recovery_unavailable",
                            "The request completed previously, but its durable result payload is unavailable.");
                        return;

                    case DurableReplayAction.RedeliverResult:
                        try
                        {
                            await SendSerializedResultAsync(ledgerRecord.ResultEnvelopeJson!);
                            await _requestLedger.MarkDeliveredAsync(ledgerRecord);
                            _status($"Re-delivered durable result for {request.Id} without re-executing {request.Tool}.");
                        }
                        catch (Exception ex)
                        {
                            _status($"Durable result delivery for {request.Id} is still pending: {ex.Message}");
                        }

                        return;

                    case DurableReplayAction.IgnoreDelivered:
                        _status($"Ignored already delivered durable request {request.Id}.");
                        return;

                    default:
                        throw new InvalidOperationException($"Unsupported durable replay action: {replayAction}.");
                }
            }
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

            ledgerRecord = await _requestLedger.MarkExecutingAsync(ledgerRecord);

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

    private async Task CompleteAndDeliverAsync(
        BridgeRequest request,
        DurableRequestRecord ledgerRecord,
        BridgeResult result,
        bool ok,
        string? errorCode,
        long elapsedMs,
        string deliveredStatus)
    {
        var prepared = BridgeResultTransport.Prepare(result, ok, errorCode);

        var completed = await _requestLedger.MarkCompletedAsync(
            ledgerRecord,
            prepared.Ok,
            prepared.ErrorCode,
            elapsedMs,
            prepared.EnvelopeJson);

        try
        {
            await WriteAuditAsync(request, prepared.Ok, prepared.ErrorCode, elapsedMs);
        }
        catch (Exception ex)
        {
            _status($"Audit write failed for {request.Id}: {ex.Message}");
        }

        try
        {
            await SendSerializedResultAsync(prepared.EnvelopeJson);
        }
        catch (Exception ex)
        {
            _status(
                $"{request.Tool} completed locally, but result delivery is pending recovery: {ex.Message}");
            return;
        }

        try
        {
            await _requestLedger.MarkDeliveredAsync(completed);
        }
        catch (Exception ex)
        {
            _status(
                $"{request.Tool} result was delivered, but durable delivery state could not be committed: {ex.Message}");
            return;
        }

        _status(prepared.ReplacedOversizeResult
            ? $"{request.Tool} completed, but its result exceeded the {BridgeResultTransport.MaxMessageBytes} byte bridge transport limit."
            : deliveredStatus);
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

            await SendResultAsync(envelope);
        }
        catch (Exception ex)
        {
            _status($"Could not deliver protocol error for {request.Id}: {ex.Message}");
        }
    }

    private Task SendResultAsync(BridgeResult result)
    {
        var prepared = BridgeResultTransport.Prepare(
            result,
            result.Ok,
            result.Error?.Code);

        return SendSerializedResultAsync(prepared.EnvelopeJson);
    }

    private async Task SendSerializedResultAsync(string json)
    {
        var message = BridgeResultTransport.FormatMessage(json);
        var sent = await _sendToChat(message);

        if (!sent)
        {
            throw new InvalidOperationException("Could not inject bridge result into the ChatGPT composer.");
        }
    }

    private static string GetDataRoot()
        => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge");

    private static string GetRequestLedgerPath()
        => Path.Combine(GetDataRoot(), "state", "requests");

    private static bool IsValidSessionId(string value)
        => value.Length == 32 && value.All(Uri.IsHexDigit);

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
}
