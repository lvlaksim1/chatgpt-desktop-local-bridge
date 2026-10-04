using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public enum PrivateMutationOutcome
{
    Confirmed,
    Rejected,
    UnknownOutcome,
    StaleContext
}

public sealed record PrivateBackendResult(
    bool Ok,
    int Status,
    string Endpoint,
    string ResponseSchema,
    int ResponseLength,
    string ResponseSha256,
    long ElapsedMs,
    PrivateMutationOutcome Outcome,
    string? Error);

public sealed class ChatGptPrivateTransport
{
    private static readonly HashSet<string> AllowedReadPaths =
        new(StringComparer.Ordinal)
        {
            "/backend-api/automations",
            "/backend-api/files/library",
            "/backend-api/files/library/storage/usage"
        };

    private readonly WebView2 _browser;
    private readonly RequestBindingGuard _binding;

    public ChatGptPrivateTransport(WebView2 browser)
    {
        _browser = browser;
        _binding = new RequestBindingGuard(browser);
    }

    public RequestBinding CaptureBinding() => _binding.Capture();

    public Task<PrivateBackendResult> ListAutomationsAsync(string filter)
    {
        if (filter is not ("scheduled" or "paused" or "finished"))
        {
            throw new ArgumentOutOfRangeException(nameof(filter));
        }

        return ExecuteReadAsync(
            $"/backend-api/automations?filter={Uri.EscapeDataString(filter)}");
    }

    public Task<PrivateBackendResult> ListLibraryAsync(int limit = 100)
    {
        limit = Math.Clamp(limit, 1, 100);
        return ExecuteAsync(
            "POST",
            "/backend-api/files/library",
            JsonSerializer.Serialize(new { limit }),
            isMutation: false);
    }

    public Task<PrivateBackendResult> LibraryStorageUsageAsync()
        => ExecuteReadAsync("/backend-api/files/library/storage/usage");

    public Task<PrivateBackendResult> GetLatestRunAsync(string automationId)
    {
        var id = ValidateOpaqueId(automationId);
        return ExecuteReadAsync(
            $"/backend-api/automation/{Uri.EscapeDataString(id)}/latest_backing_run?include_snapshot=true",
            allowParameterizedPath: true);
    }

    public async Task<PrivateBackendResult> ReplayCapturedMutationAsync(
        ScheduledTaskTrafficEntry entry,
        string body)
    {
        var method = entry.Method.Trim().ToUpperInvariant();
        if (method is not ("POST" or "PUT" or "PATCH" or "DELETE"))
        {
            throw new InvalidOperationException("Selected request is not a mutation.");
        }

        if (!ScheduledTaskTrafficFilter.IsAllowedReplayUrl(entry.ReplayUrl))
        {
            throw new InvalidOperationException("Captured endpoint is outside chatgpt.com.");
        }

        var uri = new Uri(entry.ReplayUrl);
        return await ExecuteAsync(
            method,
            uri.PathAndQuery,
            body,
            isMutation: true,
            allowObservedMutation: true);
    }

    private Task<PrivateBackendResult> ExecuteReadAsync(
        string pathAndQuery,
        bool allowParameterizedPath = false)
    {
        var path = new Uri(new Uri("https://chatgpt.com"), pathAndQuery).AbsolutePath;
        if (!allowParameterizedPath && !AllowedReadPaths.Contains(path))
        {
            throw new InvalidOperationException(
                $"Private read endpoint is not allowlisted: {path}");
        }

        return ExecuteAsync("GET", pathAndQuery, null, isMutation: false);
    }

    private async Task<PrivateBackendResult> ExecuteAsync(
        string method,
        string pathAndQuery,
        string? body,
        bool isMutation,
        bool allowObservedMutation = false)
    {
        if (_browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException("ChatGPT WebView is not initialized.");
        }

        if (!pathAndQuery.StartsWith("/backend-api/", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Private transport is restricted to /backend-api/.");
        }

        if (isMutation && !allowObservedMutation)
        {
            throw new InvalidOperationException(
                "Mutation endpoint must first be observed in the current frontend session.");
        }

        if (!string.IsNullOrWhiteSpace(body))
        {
            using var _ = JsonDocument.Parse(body);
        }

        var binding = _binding.Capture();
        var payload = JsonSerializer.Serialize(new
        {
            method,
            path = pathAndQuery,
            body
        });

        var script = """
            (async () => {
              const p = PAYLOAD;
              const started = performance.now();
              const controller = new AbortController();
              const timeout = setTimeout(() => controller.abort(), 20000);
              try {
                const options = {
                  method: p.method,
                  credentials: 'include',
                  redirect: 'follow',
                  signal: controller.signal,
                  headers: { 'accept': 'application/json, text/plain, */*' }
                };
                if (p.body !== null) {
                  options.headers['content-type'] = 'application/json';
                  options.body = p.body;
                }
                const response = await fetch(p.path, options);
                let text = await response.text();
                if (text.length > 500000) text = text.slice(0, 500000);
                return {
                  ok: response.ok,
                  status: response.status,
                  endpoint: new URL(response.url).pathname,
                  text,
                  elapsedMs: Math.round(performance.now() - started),
                  error: null
                };
              } catch (error) {
                return {
                  ok: false,
                  status: 0,
                  endpoint: p.path.split('?')[0],
                  text: '',
                  elapsedMs: Math.round(performance.now() - started),
                  error: String(error)
                };
              } finally {
                clearTimeout(timeout);
              }
            })()
            """.Replace("PAYLOAD", payload);

        ScriptResult? result;
        try
        {
            var raw = await _browser.ExecuteScriptAsync(script);
            result = JsonSerializer.Deserialize<ScriptResult>(
                raw,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
        }
        catch (Exception ex)
        {
            return new PrivateBackendResult(
                false, 0, pathAndQuery.Split('?')[0], "(no response)", 0,
                Sha256(string.Empty), 0,
                isMutation
                    ? PrivateMutationOutcome.UnknownOutcome
                    : PrivateMutationOutcome.Rejected,
                ex.Message);
        }

        try
        {
            _binding.Validate(binding);
        }
        catch (Exception ex)
        {
            return new PrivateBackendResult(
                false,
                result?.Status ?? 0,
                result?.Endpoint ?? pathAndQuery.Split('?')[0],
                "(discarded: stale context)",
                0,
                Sha256(string.Empty),
                result?.ElapsedMs ?? 0,
                PrivateMutationOutcome.StaleContext,
                ex.Message);
        }

        if (result is null)
        {
            return new PrivateBackendResult(
                false, 0, pathAndQuery.Split('?')[0], "(no result)", 0,
                Sha256(string.Empty), 0,
                isMutation
                    ? PrivateMutationOutcome.UnknownOutcome
                    : PrivateMutationOutcome.Rejected,
                "No page-context result.");
        }

        var text = result.Text ?? string.Empty;
        var outcome = result.Ok
            ? PrivateMutationOutcome.Confirmed
            : isMutation && result.Status == 0
                ? PrivateMutationOutcome.UnknownOutcome
                : PrivateMutationOutcome.Rejected;

        return new PrivateBackendResult(
            result.Ok,
            result.Status,
            result.Endpoint ?? pathAndQuery.Split('?')[0],
            JsonShape.Describe(text),
            text.Length,
            Sha256(text),
            result.ElapsedMs,
            outcome,
            result.Error);
    }

    private static string ValidateOpaqueId(string value)
    {
        var id = value.Trim();
        if (id.Length is < 1 or > 200 ||
            id.Any(ch => !(char.IsLetterOrDigit(ch) || ch is '-' or '_')))
        {
            throw new ArgumentException("Invalid opaque backend id.", nameof(value));
        }

        return id;
    }

    private static string Sha256(string value)
        => Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(value)))
            .ToLowerInvariant();

    private sealed class ScriptResult
    {
        public bool Ok { get; set; }
        public int Status { get; set; }
        public string? Endpoint { get; set; }
        public string? Text { get; set; }
        public long ElapsedMs { get; set; }
        public string? Error { get; set; }
    }
}
