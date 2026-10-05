using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record BackendReplayResult(
    bool Ok,
    int Status,
    string Url,
    string ResponseSchema,
    int ResponseLength,
    string ResponseSha256,
    bool? ContainsExpected,
    long ElapsedMs,
    string? Error);

public sealed class PageContextBackendReplay
{
    private readonly WebView2 _browser;

    public PageContextBackendReplay(WebView2 browser)
    {
        _browser = browser;
    }

    public async Task<BackendReplayResult> ExecuteAsync(
        ScheduledTaskTrafficEntry entry,
        string? requestBodyOverride,
        string? expectedText)
    {
        if (_browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException(
                "The active ChatGPT WebView is not initialized.");
        }

        if (!ScheduledTaskTrafficFilter.IsAllowedReplayUrl(entry.ReplayUrl))
        {
            throw new InvalidOperationException(
                "Captured endpoint is outside the allowed ChatGPT origin.");
        }

        var method = entry.Method.Trim().ToUpperInvariant();
        var body = requestBodyOverride ?? entry.RequestBody;

        if (method is "GET" or "HEAD")
        {
            body = null;
        }
        else if (method is not ("POST" or "PUT" or "PATCH" or "DELETE"))
        {
            throw new InvalidOperationException(
                $"Replay method '{method}' is not supported.");
        }

        if (!string.IsNullOrWhiteSpace(body))
        {
            try
            {
                using var _ = JsonDocument.Parse(body);
            }
            catch
            {
                throw new InvalidOperationException(
                    "Mutation replay is limited to JSON request bodies.");
            }
        }

        var payload = JsonSerializer.Serialize(new
        {
            url = entry.ReplayUrl,
            method,
            body,
            expected = string.IsNullOrEmpty(expectedText)
                ? null
                : expectedText
        });

        var asyncBody = """
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
                if (text.length > 500000) {
                  text = text.slice(0, 500000);
                }

                return {
                  ok: response.ok,
                  status: response.status,
                  url: response.url,
                  text,
                  containsExpected: p.expected === null
                    ? null
                    : text.includes(p.expected),
                  elapsedMs: Math.round(performance.now() - started),
                  error: null
                };
              } catch (error) {
                return {
                  ok: false,
                  status: 0,
                  url: p.url,
                  text: '',
                  containsExpected: null,
                  elapsedMs: Math.round(performance.now() - started),
                  error: String(error)
                };
              } finally {
                clearTimeout(timeout);
              }
            """.Replace("PAYLOAD", payload);

        var result = await PageContextAsyncExecutor.ExecuteAsync<ReplayScriptResult>(
            _browser,
            asyncBody,
            TimeSpan.FromSeconds(25));

        var responseText = result.Text ?? string.Empty;
        var hash = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(responseText)))
            .ToLowerInvariant();

        return new BackendReplayResult(
            result.Ok,
            result.Status,
            ScheduledTaskTrafficFilter.SanitizeUrl(
                result.Url ?? entry.ReplayUrl),
            JsonShape.Describe(responseText),
            responseText.Length,
            hash,
            result.ContainsExpected,
            result.ElapsedMs,
            result.Error);
    }

    private sealed class ReplayScriptResult
    {
        public bool Ok { get; set; }
        public int Status { get; set; }
        public string? Url { get; set; }
        public string? Text { get; set; }
        public bool? ContainsExpected { get; set; }
        public long ElapsedMs { get; set; }
        public string? Error { get; set; }
    }
}
