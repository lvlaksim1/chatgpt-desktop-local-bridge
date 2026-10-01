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
    private readonly ToolRouter _router = new();
    private readonly HashSet<string> _executedRequestIds = new(StringComparer.Ordinal);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly string _logDirectory;

    public BridgeHost(
        PermissionPolicy policy,
        Func<string, Task<bool>> sendToChat,
        Action<string> status)
    {
        _policy = policy;
        _sendToChat = sendToChat;
        _status = status;
        SessionId = Guid.NewGuid().ToString("N");

        _logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "logs");
        Directory.CreateDirectory(_logDirectory);
    }

    public string SessionId { get; }

    public string CreateBootstrapMessage() => $$"""
{{BootstrapStart}}
You are running inside a custom Windows ChatGPT client with Local Bridge v1.

Current bridge session:
{{SessionId}}

When you need local-computer data, respond with EXACTLY ONE machine request and no human prose:

{{RequestStart}}
{
  "session": "{{SessionId}}",
  "id": "req-<unique-id>",
  "tool": "<tool-name>",
  "args": { }
}
{{RequestEnd}}

Available tools:
1. system.info
   args: {}

2. fs.list
   args: { "path": "C:\\some\\directory" }

3. fs.read_text
   args: { "path": "C:\\some\\file.txt", "max_chars": 200000 }

Rules:
- Use the bridge only when local data/action is needed.
- Never invent a LOCAL_BRIDGE_RESULT.
- One request per assistant turn.
- Wait for LOCAL_BRIDGE_RESULT_V1 before continuing.
- After a result, continue normally in the user's language.
- Do not wrap a bridge request in Markdown fences.
- The session value must exactly match the session above.
{{BootstrapEnd}}
"""

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

            if (!_executedRequestIds.Add(request.Id))
            {
                _status($"Ignored duplicate request {request.Id}.");
                return;
            }

            var capability = ToolRouter.GetCapability(request.Tool);
            var decision = _policy.GetDecision(capability);

            if (decision == PermissionDecision.Deny)
            {
                await SendErrorAsync(request, "permission_denied", $"Capability {capability} is denied.");
                await WriteAuditAsync(request, false, "permission_denied", 0);
                return;
            }

            if (decision == PermissionDecision.Ask)
            {
                await SendErrorAsync(
                    request,
                    "permission_requires_confirmation",
                    $"Capability {capability} is configured as ASK. Interactive confirmation UI is the next implementation stage.");
                await WriteAuditAsync(request, false, "permission_requires_confirmation", 0);
                return;
            }

            var stopwatch = Stopwatch.StartNew();
            try
            {
                _status($"Running {request.Tool} ({request.Id})…");
                var result = await _router.ExecuteAsync(request.Tool, request.Args);
                stopwatch.Stop();

                var envelope = new BridgeResult(SessionId, request.Id, true, result);
                await SendResultAsync(envelope);
                await WriteAuditAsync(request, true, null, stopwatch.ElapsedMilliseconds);
                _status($"{request.Tool} completed in {stopwatch.ElapsedMilliseconds} ms.");
            }
            catch (BridgeToolException ex)
            {
                stopwatch.Stop();
                await SendErrorAsync(request, ex.Code, ex.Message);
                await WriteAuditAsync(request, false, ex.Code, stopwatch.ElapsedMilliseconds);
                _status($"{request.Tool} failed: {ex.Message}");
            }
            catch (Exception ex)
            {
                stopwatch.Stop();
                await SendErrorAsync(request, "tool_error", ex.Message);
                await WriteAuditAsync(request, false, "tool_error", stopwatch.ElapsedMilliseconds);
                _status($"{request.Tool} failed: {ex.Message}");
            }
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task SendErrorAsync(BridgeRequest request, string code, string message)
    {
        var envelope = new BridgeResult(
            SessionId,
            request.Id,
            false,
            Error: new BridgeError(code, message));

        await SendResultAsync(envelope);
    }

    private async Task SendResultAsync(BridgeResult result)
    {
        var json = JsonSerializer.Serialize(result, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower
        });

        var message = $"{ResultStart}\n{json}\n{ResultEnd}";
        var sent = await _sendToChat(message);

        if (!sent)
        {
            throw new InvalidOperationException("Could not inject bridge result into the ChatGPT composer.");
        }
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
}
