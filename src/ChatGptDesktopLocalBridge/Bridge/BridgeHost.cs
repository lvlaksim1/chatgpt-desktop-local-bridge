using System.Diagnostics;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.Bridge;

public sealed record BridgeStopResult(
    bool CancellationRequested,
    int StoppedProcesses);

public sealed class BridgeHost : IDisposable
{
    private const string RequestStart = "[[LOCAL_BRIDGE_REQUEST_V1]]";
    private const string RequestEnd = "[[/LOCAL_BRIDGE_REQUEST_V1]]";
    private const string BootstrapStart = "[[LOCAL_BRIDGE_BOOTSTRAP_V1]]";
    private const string BootstrapEnd = "[[/LOCAL_BRIDGE_BOOTSTRAP_V1]]";

    private readonly PermissionPolicy _policy;
    private readonly Func<string, Task<bool>> _sendToChat;
    private readonly Action<string> _status;
    private readonly Func<BridgePermissionPrompt, Task<bool>>? _confirmPermission;
    private readonly Action<BridgeActivityEvent>? _activity;
    private readonly ToolRouter _router;
    private readonly DurableRequestLedger _requestLedger;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _activeExecutionSync = new();
    private CancellationTokenSource? _activeExecutionCancellation;
    private readonly string _logDirectory;

    public BridgeHost(
        PermissionPolicy policy,
        Func<string, Task<bool>> sendToChat,
        Action<string> status,
        string? sessionId = null,
        Func<BridgePermissionPrompt, Task<bool>>? confirmPermission = null,
        Action<BridgeActivityEvent>? activity = null,
        Func<string, CancellationToken, Task<BridgePlannedAction>>? localIntentPlanner = null)
    {
        _policy = policy;
        _sendToChat = sendToChat;
        _status = status;
        _confirmPermission = confirmPermission;
        _activity = activity;
        _router = new ToolRouter(localIntentPlanner);

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
        var lines = new List<string>
        {
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
            "Available tools:"
        };

        lines.AddRange(ToolRouter.GetBootstrapToolLines());

        lines.AddRange(
        [
            "Handshake:",
            "- Immediately after receiving this bootstrap, reply with EXACTLY this single line and no other text:",
            ReadyMarker,
            string.Empty,
            "Rules:",
            "- Use the bridge only when local data/action is needed.",
            "- The current ChatGPT conversation is the planner. Use the direct fs.*, repo.*, process.*, terminal.*, and mcp.* tools yourself; do not delegate ordinary local work to a second planner.",
            "- For a multi-step local task, issue one direct request, wait for LOCAL_BRIDGE_RESULT_V1, analyze that result in this same conversation, then issue the next request if needed.",
            "- Use process.run for one bounded non-interactive command. Use terminal.open plus terminal.write/read/status/resize/close when shell state or interactivity must persist across multiple bridge turns.",
            "- After terminal.open is approved, terminal I/O remains authorized only inside that terminal session. Close the terminal when it is no longer needed.",
            "- terminal.read uses an absolute cursor. Continue from nextCursor to avoid gaps; a terminal resize may legitimately emit a fresh screen redraw.",
            "- Never invent a LOCAL_BRIDGE_RESULT.",
            "- In bridge JSON, write Windows paths with forward slashes, for example C:/Windows/win.ini. Do not use backslashes in JSON path strings.",
            "- One request per assistant turn.",
            "- Wait for LOCAL_BRIDGE_RESULT_V1 before continuing.",
            "- After a result, continue normally in the user's language.",
            "- Do not wrap a bridge request in Markdown fences.",
            "- The session value must exactly match the session above.",
            BootstrapEnd
        ]);

        return string.Join(Environment.NewLine, lines);
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

            var activityArgs = CloneArgs(request.Args);
            Emit(request, "received", activityArgs);

            if (!string.Equals(request.Session, SessionId, StringComparison.Ordinal))
            {
                Emit(
                    request,
                    "failed",
                    activityArgs,
                    ok: false,
                    errorCode: "invalid_session",
                    errorMessage: "Invalid bridge session.");
                _status("Rejected bridge request with an invalid session.");
                return;
            }

            var reservation = await _requestLedger.ReserveAsync(request, conversationUri);

            if (reservation.Status == DurableReservationStatus.Conflict)
            {
                Emit(
                    request,
                    "failed",
                    activityArgs,
                    ok: false,
                    errorCode: "request_id_conflict",
                    errorMessage: "The same request id was reused with a different payload.");
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
                Emit(
                    request,
                    "failed",
                    activityArgs,
                    ok: false,
                    errorCode: "permission_denied",
                    errorMessage: $"Capability {capability} is denied.");

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
                var approved = false;

                if (_confirmPermission is not null)
                {
                    try
                    {
                        approved = await _confirmPermission(
                            new BridgePermissionPrompt(
                                request.Tool,
                                capability,
                                ToolRouter.GetPermissionSummary(request.Tool, request.Args)));
                    }
                    catch (Exception ex)
                    {
                        _status($"Permission confirmation failed for {request.Id}: {ex.Message}");
                    }
                }

                if (!approved)
                {
                    Emit(
                        request,
                        "failed",
                        activityArgs,
                        ok: false,
                        errorCode: "permission_not_approved",
                        errorMessage: $"Capability {capability} was not approved.");

                    var envelope = new BridgeResult(
                        SessionId,
                        request.Id,
                        false,
                        Error: new BridgeError(
                            "permission_not_approved",
                            $"Capability {capability} requires confirmation and was not approved."));

                    await CompleteAndDeliverAsync(
                        request,
                        ledgerRecord,
                        envelope,
                        false,
                        "permission_not_approved",
                        0,
                        $"{request.Tool} was not approved.");
                    return;
                }

                _status($"Permission approved for {request.Tool} ({request.Id}).");
            }

            ledgerRecord = await _requestLedger.MarkExecutingAsync(ledgerRecord);

            var stopwatch = Stopwatch.StartNew();
            BridgeResult resultEnvelope;
            bool ok;
            string? errorCode;
            string deliveredStatus;

            using var executionCancellation = new CancellationTokenSource();
            lock (_activeExecutionSync)
            {
                _activeExecutionCancellation = executionCancellation;
            }

            try
            {
                Emit(request, "running", activityArgs);
                _status($"Running {request.Tool} ({request.Id})…");
                var result = await _router.ExecuteAsync(
                    request.Tool,
                    request.Args,
                    executionCancellation.Token);
                stopwatch.Stop();

                ok = true;
                errorCode = null;
                resultEnvelope = new BridgeResult(SessionId, request.Id, true, result);
                Emit(
                    request,
                    "completed",
                    activityArgs,
                    ok: true,
                    elapsedMs: stopwatch.ElapsedMilliseconds,
                    result: JsonSerializer.SerializeToElement(result));
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
                Emit(
                    request,
                    "failed",
                    activityArgs,
                    ok: false,
                    elapsedMs: stopwatch.ElapsedMilliseconds,
                    errorCode: ex.Code,
                    errorMessage: ex.Message);
                deliveredStatus = $"{request.Tool} failed: {ex.Message}";
            }
            catch (OperationCanceledException)
            {
                stopwatch.Stop();

                ok = false;
                errorCode = "tool_cancelled";
                resultEnvelope = new BridgeResult(
                    SessionId,
                    request.Id,
                    false,
                    Error: new BridgeError(
                        "tool_cancelled",
                        "The local tool execution was stopped."));
                Emit(
                    request,
                    "failed",
                    activityArgs,
                    ok: false,
                    elapsedMs: stopwatch.ElapsedMilliseconds,
                    errorCode: "tool_cancelled",
                    errorMessage: "The local tool execution was stopped.");
                deliveredStatus = $"{request.Tool} was stopped.";
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
                Emit(
                    request,
                    "failed",
                    activityArgs,
                    ok: false,
                    elapsedMs: stopwatch.ElapsedMilliseconds,
                    errorCode: "tool_error",
                    errorMessage: ex.Message);
                deliveredStatus = $"{request.Tool} failed: {ex.Message}";
            }
            finally
            {
                lock (_activeExecutionSync)
                {
                    if (ReferenceEquals(_activeExecutionCancellation, executionCancellation))
                    {
                        _activeExecutionCancellation = null;
                    }
                }
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
            Emit(
                request,
                "delivery_failed",
                CloneArgs(request.Args),
                ok: false,
                elapsedMs: elapsedMs,
                errorCode: "result_delivery_failed",
                errorMessage: ex.Message);
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

    public BridgeStopResult StopActiveWork()
    {
        var cancellationRequested = false;
        lock (_activeExecutionSync)
        {
            if (_activeExecutionCancellation is not null &&
                !_activeExecutionCancellation.IsCancellationRequested)
            {
                _activeExecutionCancellation.Cancel();
                cancellationRequested = true;
            }
        }

        var stoppedProcesses = _router.StopActiveProcesses();
        return new BridgeStopResult(cancellationRequested, stoppedProcesses);
    }

    public void Dispose()
    {
        StopActiveWork();
        _router.Dispose();

        lock (_activeExecutionSync)
        {
            _activeExecutionCancellation?.Dispose();
            _activeExecutionCancellation = null;
        }

        _gate.Dispose();
    }

    private void Emit(
        BridgeRequest request,
        string phase,
        JsonElement args,
        bool? ok = null,
        long? elapsedMs = null,
        JsonElement? result = null,
        string? errorCode = null,
        string? errorMessage = null)
    {
        _activity?.Invoke(
            new BridgeActivityEvent(
                DateTimeOffset.Now,
                phase,
                request.Id,
                request.Tool,
                args,
                ok,
                elapsedMs,
                result,
                errorCode,
                errorMessage));
    }

    private static JsonElement CloneArgs(JsonElement args)
    {
        if (args.ValueKind == JsonValueKind.Undefined)
        {
            return JsonSerializer.SerializeToElement(new { });
        }

        return args.Clone();
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