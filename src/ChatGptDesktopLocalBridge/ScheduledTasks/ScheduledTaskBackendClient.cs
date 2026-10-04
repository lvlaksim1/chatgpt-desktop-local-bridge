using System.Diagnostics;
using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record ScheduledTaskBackendResponse(
    bool Ok,
    int Status,
    string Url,
    string Body,
    long ElapsedMs);

public sealed class ScheduledTaskBackendClient
{
    private static readonly HashSet<string> AllowedMethods =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "GET",
            "POST",
            "PUT",
            "PATCH"
        };

    private readonly WebView2 _browser;

    public ScheduledTaskBackendClient(WebView2 browser)
    {
        _browser = browser;
    }

    public async Task<ScheduledTaskBackendResponse> ExecuteAsync(
        ScheduledTaskRequestTemplate template,
        string taskId,
        string? prompt = null,
        bool? enabled = null,
        DateTimeOffset? startAt = null)
    {
        if (_browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException(
                "The active ChatGPT WebView is not initialized.");
        }

        var method = template.Method.Trim().ToUpperInvariant();
        if (!AllowedMethods.Contains(method))
        {
            throw new InvalidOperationException(
                $"Request method '{method}' is not allowed by the transport probe.");
        }

        var url = ScheduledTaskProbeSanitizer.ExpandUrl(
            template.UrlTemplate,
            taskId);

        if (!ScheduledTaskProbeSanitizer.IsCandidateTaskUrl(url))
        {
            throw new InvalidOperationException(
                "The learned request no longer resolves to an allowed ChatGPT Scheduled Tasks URL.");
        }

        var bodyNode = ScheduledTaskProbeSanitizer.BuildBody(
            template.BodyTemplate,
            taskId,
            prompt,
            enabled,
            startAt);

        var body = bodyNode?.ToJsonString();

        if (!string.IsNullOrWhiteSpace(body) &&
            body.Contains("<redacted>", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                "The captured body contains redacted fields and is not safe to replay. Capture a request whose body does not contain sensitive fields.");
        }

        var payload = JsonSerializer.Serialize(new
        {
            url,
            method,
            body
        });

        var script = """
            (async () => {
              const p = PAYLOAD;
              const started = performance.now();
              const options = {
                method: p.method,
                credentials: 'include',
                redirect: 'error',
                headers: {
                  'accept': 'application/json, text/plain, */*'
                }
              };

              if (p.body !== null) {
                options.headers['content-type'] = 'application/json';
                options.body = p.body;
              }

              const response = await fetch(p.url, options);
              let text = await response.text();

              if (text.length > 200000) {
                text = text.slice(0, 200000) + '\n<response truncated>';
              }

              return {
                ok: response.ok,
                status: response.status,
                url: response.url,
                body: text,
                elapsedMs: Math.round(performance.now() - started)
              };
            })()
            """.Replace("PAYLOAD", payload);

        var stopwatch = Stopwatch.StartNew();
        string raw;

        try
        {
            raw = await _browser.ExecuteScriptAsync(script);
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"WebView same-session request failed before a response was returned: {ex.Message}");
        }

        stopwatch.Stop();

        BackendScriptResult? result;
        try
        {
            result = JsonSerializer.Deserialize<BackendScriptResult>(
                raw,
                new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                $"Could not decode WebView fetch result: {ex.Message}");
        }

        if (result is null)
        {
            throw new InvalidOperationException(
                "WebView fetch returned no result.");
        }

        return new ScheduledTaskBackendResponse(
            result.Ok,
            result.Status,
            result.Url ?? url,
            ScheduledTaskProbeSanitizer.SanitizeBody(result.Body) ?? string.Empty,
            result.ElapsedMs > 0
                ? result.ElapsedMs
                : stopwatch.ElapsedMilliseconds);
    }

    private sealed class BackendScriptResult
    {
        public bool Ok { get; set; }
        public int Status { get; set; }
        public string? Url { get; set; }
        public string? Body { get; set; }
        public long ElapsedMs { get; set; }
    }
}
