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
    private readonly Action<BridgeActivityEvent>? _activity;
    private readonly ToolRouter _router = new();
    private readonly HashSet<string> _executedRequestIds = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _logDirectory;

    public BridgeHost(
        PermissionPolicy policy,
        Func<string, Task<bool>> sendToChat,
        Action<string> status,
        Action<BridgeActivityEvent>? activity = null)
    {
        _policy = policy;
        _sendToChat = sendToChat;
        _status = status;
        _activity = activity;
        SessionId = Guid.NewGuid().ToString("N");

        _logDirectory = Path.Combine(
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
            "4. fs.write_text",
            "   args: { \"path\": \"C:/some/file.txt\", \"text\": \"text\", \"overwrite\": false, \"create_directories\": false }",
            string.Empty,
            "5. fs.append_text",
            "   args: { \"path\": \"C:/some/file.txt\", \"text\": \"\\r\\nmore text\", \"create_if_missing\": false, \"create_directories\": false }",
            string.Empty,
            "6. fs.write_file",
            "   args: { \"path\": \"C:/some/file.bin\", \"content\": \"BASE64_OR_TEXT\", \"encoding\": \"base64\", \"overwrite\": false, \"create_directories\": false }",
            "   decoded file limit: 1048576 bytes; encoding may be base64 or utf8",
            string.Empty,
            "7. process.run",
            "   args: { \"file\": \"git.exe\", \"arguments\": [\"status\"], \"cwd\": \"C:/repo\", \"timeout_ms\": 120000, \"max_output_chars\": 200000 }",
            "   runs one process synchronously; returns exit_code, stdout, stderr, timeout/truncation metadata",
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
                    new JsonSerializerOptions
                    {
                        PropertyNameCaseInsensitive = true
                    });
            }
            catch (Exception ex)
            {
                _status($"Отклонён некорректный запрос Local Bridge: {ex.Message}");
                return;
            }

            if (request is null ||
                string.IsNullOrWhiteSpace(request.Id) ||
                string.IsNullOrWhiteSpace(request.Tool))
            {
                _status("Отклонён некорректный запрос Local Bridge.");
                return;
            }

            var args = CloneArgs(request.Args);
            Emit(request, "received", args);

            if (!string.Equals(request.Session, SessionId, StringComparison.Ordinal))
            {
                Emit(
                    request,
                    "failed",
                    args,
                    ok: false,
                    errorCode: "invalid_session",
                    errorMessage: "Invalid bridge session.");

                _status("Отклонён запрос с неверной сессией Local Bridge.");
                return;
            }

            if (!_executedRequestIds.Add(request.Id))
            {
                _status($"Повторный запрос {request.Id} проигнорирован.");
                return;
            }

            var capability = ToolRouter.GetCapability(request.Tool);
            var decision = _policy.GetDecision(capability);

            if (decision == PermissionDecision.Deny)
            {
                Emit(
                    request,
                    "failed",
                    args,
                    ok: false,
                    errorCode: "permission_denied",
                    errorMessage: $"Capability {capability} is denied.");

                await TrySendErrorAsync(
                    request,
                    args,
                    "permission_denied",
                    $"Capability {capability} is denied.");

                await WriteAuditAsync(
                    request,
                    false,
                    "permission_denied",
                    0);

                return;
            }

            if (decision == PermissionDecision.Ask)
            {
                const string code = "permission_requires_confirmation";
                var message =
                    $"Capability {capability} is configured as ASK. Interactive confirmation UI is not enabled yet.";

                Emit(
                    request,
                    "failed",
                    args,
                    ok: false,
                    errorCode: code,
                    errorMessage: message);

                await TrySendErrorAsync(request, args, code, message);
                await WriteAuditAsync(request, false, code, 0);
                return;
            }

            var stopwatch = Stopwatch.StartNew();

            try
            {
                Emit(request, "running", args);
                _status($"Выполняется {request.Tool} ({request.Id})…");

                var result = await _router.ExecuteAsync(
                    request.Tool,
                    request.Args);

                stopwatch.Stop();

                var resultElement = JsonSerializer.SerializeToElement(result);

                Emit(
                    request,
                    "completed",
                    args,
                    ok: true,
                    elapsedMs: stopwatch.ElapsedMilliseconds,
                    result: resultElement);

                var envelope = new BridgeResult(
                    SessionId,
                    request.Id,
                    true,
                    result);

                var delivered = await TrySendResultAsync(
                    request,
                    args,
                    envelope,
                    stopwatch.ElapsedMilliseconds);

                await WriteAuditAsync(
                    request,
                    delivered,
                    delivered ? null : "result_delivery_failed",
                    stopwatch.ElapsedMilliseconds);

                _status(delivered
                    ? $"{request.Tool} завершён за {stopwatch.ElapsedMilliseconds} мс."
                    : $"{request.Tool} выполнен, но результат не доставлен в ChatGPT.");
            }
            catch (BridgeToolException ex)
            {
                stopwatch.Stop();

                Emit(
                    request,
                    "failed",
                    args,
                    ok: false,
                    elapsedMs: stopwatch.ElapsedMilliseconds,
                    errorCode: ex.Code,
                    errorMessage: ex.Message);

                await TrySendErrorAsync(
                    request,
                    args,
                    ex.Code,
                    ex.Message,
                    stopwatch.ElapsedMilliseconds);

                await WriteAuditAsync(
                    request,
                    false,
                    ex.Code,
                    stopwatch.ElapsedMilliseconds);

                _status($"{request.Tool}: ошибка — {ex.Message}");
            }
            catch (Exception ex)
            {
                stopwatch.Stop();

                Emit(
                    request,
                    "failed",
                    args,
                    ok: false,
                    elapsedMs: stopwatch.ElapsedMilliseconds,
                    errorCode: "tool_error",
                    errorMessage: ex.Message);

                await TrySendErrorAsync(
                    request,
                    args,
                    "tool_error",
                    ex.Message,
                    stopwatch.ElapsedMilliseconds);

                await WriteAuditAsync(
                    request,
                    false,
                    "tool_error",
                    stopwatch.ElapsedMilliseconds);

                _status($"{request.Tool}: ошибка — {ex.Message}");
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<bool> TrySendErrorAsync(
        BridgeRequest request,
        JsonElement args,
        string code,
        string message,
        long elapsedMs = 0)
    {
        var envelope = new BridgeResult(
            SessionId,
            request.Id,
            false,
            Error: new BridgeError(code, message));

        return await TrySendResultAsync(
            request,
            args,
            envelope,
            elapsedMs);
    }

    private async Task<bool> TrySendResultAsync(
        BridgeRequest request,
        JsonElement args,
        BridgeResult result,
        long elapsedMs)
    {
        try
        {
            var json = JsonSerializer.Serialize(
                result,
                new JsonSerializerOptions
                {
                    PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
                });

            var message = $"{ResultStart}\n{json}\n{ResultEnd}";
            var sent = await _sendToChat(message);

            if (!sent)
            {
                Emit(
                    request,
                    "delivery_failed",
                    args,
                    ok: false,
                    elapsedMs: elapsedMs,
                    errorCode: "result_delivery_failed",
                    errorMessage: "Could not inject bridge result into the ChatGPT composer.");
            }

            return sent;
        }
        catch (Exception ex)
        {
            Emit(
                request,
                "delivery_failed",
                args,
                ok: false,
                elapsedMs: elapsedMs,
                errorCode: "result_delivery_failed",
                errorMessage: ex.Message);

            return false;
        }
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

        await File.AppendAllTextAsync(
            path,
            JsonSerializer.Serialize(record) + Environment.NewLine);
    }
}
