using System.Diagnostics;
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

    private readonly PermissionPolicy _policy;
    private readonly Func<string, Task<bool>> _sendToChat;
    private readonly Action<string> _status;
    private readonly ToolRouter _router;
    private readonly BridgeExecutionLedger _ledger;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _logDirectory;

    public BridgeHost(
        PermissionPolicy policy,
        Func<string, Task<bool>> sendToChat,
        Action<string> status,
        BridgeExecutionLedger? ledger = null,
        ToolRouter? router = null,
        string? logDirectory = null)
    {
        _policy = policy;
        _sendToChat = sendToChat;
        _status = status;
        _router = router ?? new ToolRouter();
        _ledger = ledger ?? new BridgeExecutionLedger();
        SessionId = Guid.NewGuid().ToString("N");

        _logDirectory = logDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "logs");
        Directory.CreateDirectory(_logDirectory);
    }

    public string SessionId { get; }

    public string ReadyMarker => $"[[LOCAL_BRIDGE_READY_V1:{SessionId}]]";

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
            var request = ParseRequest(requestElement);
            if (request is null)
            {
                return;
            }

            if (!string.Equals(request.Session, SessionId, StringComparison.Ordinal))
            {
                _status("Rejected bridge request with an invalid session.");
                return;
            }

            var capability = BridgeCapabilityRegistry.Resolve(request.Tool);
            var fingerprint = BridgeExecutionLedger.ComputeRequestFingerprint(request);
            var existing = await _ledger.GetAsync(request.Session, request.Id);

            if (existing is not null)
            {
                await HandleExistingAsync(request, fingerprint, existing);
                return;
            }

            var record = _ledger.CreateReceived(request, capability);
            await _ledger.SaveAsync(record);

            if (!capability.Known)
            {
                await PersistResultAndDeliverAsync(
                    request,
                    capability,
                    record,
                    new BridgeResult(
                        SessionId,
                        request.Id,
                        false,
                        Error: new BridgeError(
                            "unknown_tool",
                            $"Unknown local tool: {request.Tool}")),
                    executionOk: false,
                    errorCode: "unknown_tool",
                    elapsedMs: 0);
                return;
            }

            var decision = _policy.GetDecision(capability.Capability);

            if (decision == PermissionDecision.Deny)
            {
                await PersistResultAndDeliverAsync(
                    request,
                    capability,
                    record,
                    new BridgeResult(
                        SessionId,
                        request.Id,
                        false,
                        Error: new BridgeError(
                            "permission_denied",
                            $"Capability {capability.Capability} is denied.")),
                    executionOk: false,
                    errorCode: "permission_denied",
                    elapsedMs: 0);
                return;
            }

            if (decision == PermissionDecision.Ask)
            {
                await PersistResultAndDeliverAsync(
                    request,
                    capability,
                    record,
                    new BridgeResult(
                        SessionId,
                        request.Id,
                        false,
                        Error: new BridgeError(
                            "permission_requires_confirmation",
                            $"Capability {capability.Capability} is configured as ASK. Interactive confirmation UI is the next implementation stage.")),
                    executionOk: false,
                    errorCode: "permission_requires_confirmation",
                    elapsedMs: 0);
                return;
            }

            await ExecuteOnceAsync(request, capability, record);
        }
        finally
        {
            _gate.Release();
        }
    }

    private BridgeRequest? ParseRequest(JsonElement requestElement)
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
            return null;
        }

        if (request is null ||
            string.IsNullOrWhiteSpace(request.Session) ||
            string.IsNullOrWhiteSpace(request.Id) ||
            string.IsNullOrWhiteSpace(request.Tool))
        {
            _status("Rejected malformed bridge request.");
            return null;
        }

        return request;
    }

    private async Task HandleExistingAsync(
        BridgeRequest request,
        string fingerprint,
        BridgeLedgerRecord existing)
    {
        if (!string.Equals(
                fingerprint,
                existing.RequestFingerprint,
                StringComparison.Ordinal))
        {
            _status($"Rejected conflicting duplicate request {request.Id}.");
            await TrySendTransientErrorAsync(
                request,
                "request_id_conflict",
                "The same bridge request id was reused with different tool arguments.");
            return;
        }

        switch (existing.State)
        {
            case BridgeRequestState.Received:
                var capability = BridgeCapabilityRegistry.Resolve(existing.Tool);
                _status($"Resuming received request {request.Id} before local execution.");
                await ResumeReceivedAsync(request, capability, existing);
                return;

            case BridgeRequestState.ExecutionStarted:
                _status(
                    $"Request {request.Id} has uncertain execution state; refusing blind re-execution.");
                await TrySendTransientErrorAsync(
                    request,
                    "execution_state_uncertain",
                    "Local execution may have started before an interruption. The bridge will not execute this request again automatically.");
                return;

            case BridgeRequestState.ResultReady:
                _status($"Delivering durable result for duplicate request {request.Id}.");
                await DeliverStoredResultAsync(existing);
                return;

            case BridgeRequestState.DeliveryPending:
                _status(
                    $"Request {request.Id} has uncertain delivery state; refusing blind result replay.");
                await TrySendTransientErrorAsync(
                    request,
                    "delivery_state_uncertain",
                    "A durable result exists, but prior delivery may already have reached ChatGPT. The bridge will not replay it automatically.");
                return;

            case BridgeRequestState.Delivered:
                _status($"Ignored already delivered duplicate request {request.Id}.");
                return;

            default:
                throw new InvalidOperationException(
                    $"Unsupported bridge ledger state {existing.State}.");
        }
    }

    private async Task ResumeReceivedAsync(
        BridgeRequest request,
        BridgeCapabilityDefinition capability,
        BridgeLedgerRecord record)
    {
        if (!capability.Known)
        {
            await PersistResultAndDeliverAsync(
                request,
                capability,
                record,
                new BridgeResult(
                    SessionId,
                    request.Id,
                    false,
                    Error: new BridgeError(
                        "unknown_tool",
                        $"Unknown local tool: {request.Tool}")),
                executionOk: false,
                errorCode: "unknown_tool",
                elapsedMs: 0);
            return;
        }

        var decision = _policy.GetDecision(capability.Capability);
        if (decision != PermissionDecision.Auto)
        {
            var code = decision == PermissionDecision.Ask
                ? "permission_requires_confirmation"
                : "permission_denied";
            var message = decision == PermissionDecision.Ask
                ? $"Capability {capability.Capability} is configured as ASK. Interactive confirmation UI is the next implementation stage."
                : $"Capability {capability.Capability} is denied.";

            await PersistResultAndDeliverAsync(
                request,
                capability,
                record,
                new BridgeResult(
                    SessionId,
                    request.Id,
                    false,
                    Error: new BridgeError(code, message)),
                executionOk: false,
                errorCode: code,
                elapsedMs: 0);
            return;
        }

        await ExecuteOnceAsync(request, capability, record);
    }

    private async Task ExecuteOnceAsync(
        BridgeRequest request,
        BridgeCapabilityDefinition capability,
        BridgeLedgerRecord record)
    {
        var executionRecord = record with
        {
            State = BridgeRequestState.ExecutionStarted
        };
        await _ledger.SaveAsync(executionRecord);

        var stopwatch = Stopwatch.StartNew();
        BridgeResult envelope;
        bool executionOk;
        string? errorCode;

        _status($"Running {request.Tool} ({request.Id})…");

        try
        {
            var result = await _router.ExecuteAsync(request.Tool, request.Args);
            stopwatch.Stop();

            envelope = new BridgeResult(
                SessionId,
                request.Id,
                true,
                result);
            executionOk = true;
            errorCode = null;
        }
        catch (BridgeToolException ex)
        {
            stopwatch.Stop();

            envelope = new BridgeResult(
                SessionId,
                request.Id,
                false,
                Error: new BridgeError(ex.Code, ex.Message));
            executionOk = false;
            errorCode = ex.Code;
        }
        catch (Exception ex)
        {
            stopwatch.Stop();

            envelope = new BridgeResult(
                SessionId,
                request.Id,
                false,
                Error: new BridgeError("tool_error", ex.Message));
            executionOk = false;
            errorCode = "tool_error";
        }

        await PersistResultAndDeliverAsync(
            request,
            capability,
            executionRecord,
            envelope,
            executionOk,
            errorCode,
            stopwatch.ElapsedMilliseconds);
    }

    private async Task PersistResultAndDeliverAsync(
        BridgeRequest request,
        BridgeCapabilityDefinition capability,
        BridgeLedgerRecord record,
        BridgeResult envelope,
        bool executionOk,
        string? errorCode,
        long elapsedMs)
    {
        var serialized = BridgeResultCodec.SerializeBounded(
            envelope,
            capability.MaxResultBytes);

        var persistedErrorCode = serialized.Envelope.Error?.Code ?? errorCode;
        var resultRecord = record with
        {
            State = BridgeRequestState.ResultReady,
            ResultEnvelopeJson = serialized.Json,
            ExecutionOk = executionOk,
            ErrorCode = persistedErrorCode,
            ElapsedMs = elapsedMs
        };

        await _ledger.SaveAsync(resultRecord);

        await TryWriteAuditAsync(
            request,
            serialized.Envelope.Ok,
            persistedErrorCode,
            elapsedMs);

        if (serialized.WasBounded)
        {
            _status(
                $"{request.Tool} completed, but its {serialized.OriginalBytes}-byte result exceeded the {capability.MaxResultBytes}-byte bridge limit.");
        }
        else if (executionOk)
        {
            _status($"{request.Tool} completed in {elapsedMs} ms; delivering durable result.");
        }
        else
        {
            _status($"{request.Tool} failed locally; delivering durable error result.");
        }

        var delivered = await DeliverStoredResultAsync(resultRecord);
        if (!delivered)
        {
            _status(
                $"{request.Tool} result is durable, but delivery was not confirmed. Automatic replay is disabled.");
        }
    }

    private async Task<bool> DeliverStoredResultAsync(BridgeLedgerRecord record)
    {
        if (record.State == BridgeRequestState.Delivered)
        {
            return true;
        }

        if (string.IsNullOrWhiteSpace(record.ResultEnvelopeJson))
        {
            throw new InvalidOperationException(
                $"Bridge ledger result is missing for request {record.RequestId}.");
        }

        if (record.State == BridgeRequestState.DeliveryPending)
        {
            return false;
        }

        if (record.State != BridgeRequestState.ResultReady)
        {
            throw new InvalidOperationException(
                $"Request {record.RequestId} is not ready for result delivery from state {record.State}.");
        }

        var deliveryRecord = record with
        {
            State = BridgeRequestState.DeliveryPending
        };
        await _ledger.SaveAsync(deliveryRecord);

        bool sent;
        try
        {
            sent = await SendResultJsonAsync(record.ResultEnvelopeJson);
        }
        catch (Exception ex)
        {
            _status(
                $"Bridge result delivery failed for {record.RequestId}: {ex.Message}");
            return false;
        }

        if (!sent)
        {
            return false;
        }

        var deliveredRecord = deliveryRecord with
        {
            State = BridgeRequestState.Delivered
        };
        await _ledger.SaveAsync(deliveredRecord);
        return true;
    }

    private async Task<bool> SendResultJsonAsync(string json)
    {
        var message = $"{ResultStart}\n{json}\n{ResultEnd}";
        return await _sendToChat(message);
    }

    private async Task TrySendTransientErrorAsync(
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
            var serialized = BridgeResultCodec.SerializeBounded(
                envelope,
                64 * 1024);

            if (!await SendResultJsonAsync(serialized.Json))
            {
                _status(
                    $"Could not deliver transient bridge error {code} for {request.Id}.");
            }
        }
        catch (Exception ex)
        {
            _status(
                $"Could not deliver transient bridge error {code} for {request.Id}: {ex.Message}");
        }
    }

    private async Task TryWriteAuditAsync(
        BridgeRequest request,
        bool ok,
        string? errorCode,
        long elapsedMs)
    {
        try
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

            await File.AppendAllTextAsync(
                path,
                JsonSerializer.Serialize(record) + Environment.NewLine);
        }
        catch (Exception ex)
        {
            _status(
                $"Bridge audit write failed for {request.Id}: {ex.Message}");
        }
    }
}
