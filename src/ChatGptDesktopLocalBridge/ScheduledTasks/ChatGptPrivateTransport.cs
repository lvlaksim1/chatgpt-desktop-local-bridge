using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public enum PrivateTransportOutcome
{
    ConfirmedSuccess,
    ConfirmedFailure,
    UnknownOutcome,
    ContextInvalidated
}

public sealed record PrivateTransportResult(
    PrivateTransportOutcome Outcome,
    bool Ok,
    int Status,
    string Endpoint,
    string ResponseSchema,
    int ResponseLength,
    string ResponseSha256,
    long ElapsedMs,
    string? Error,
    [property: JsonIgnore] string ResponseBody);

public sealed class ChatGptPrivateTransport
{
    private readonly WebView2 _browser;
    private readonly RequestBinding _binding;

    public ChatGptPrivateTransport(WebView2 browser)
    {
        _browser = browser;
        _binding = new RequestBinding(browser);
    }

    public Task<PrivateTransportResult> GetAsync(
        string relativeEndpoint,
        int timeoutMs = 30_000)
        => SendAsync(
            "GET",
            relativeEndpoint,
            jsonBody: null,
            semanticMutation: false,
            timeoutMs);

    public Task<PrivateTransportResult> PostReadAsync(
        string relativeEndpoint,
        string jsonBody,
        int timeoutMs = 30_000)
        => SendAsync(
            "POST",
            relativeEndpoint,
            jsonBody,
            semanticMutation: false,
            timeoutMs);

    public Task<PrivateTransportResult> SendMutationAsync(
        string method,
        string relativeEndpoint,
        string? jsonBody,
        int timeoutMs = 30_000)
        => SendAsync(
            method,
            relativeEndpoint,
            jsonBody,
            semanticMutation: true,
            timeoutMs);

    public async Task<PrivateTransportResult> SendAsync(
        string method,
        string relativeEndpoint,
        string? jsonBody,
        bool semanticMutation,
        int timeoutMs)
    {
        ValidateEndpoint(relativeEndpoint);

        method = method.Trim().ToUpperInvariant();
        if (method is not ("GET" or "POST" or "PUT" or "PATCH" or "DELETE"))
        {
            throw new InvalidOperationException(
                $"Unsupported private transport method: {method}");
        }

        if (timeoutMs is < 1_000 or > 120_000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(timeoutMs),
                "Timeout must be between 1 and 120 seconds.");
        }

        if (jsonBody is not null)
        {
            try
            {
                using var _ = JsonDocument.Parse(jsonBody);
            }
            catch (Exception ex)
            {
                throw new InvalidOperationException(
                    $"Private transport body must be valid JSON: {ex.Message}");
            }
        }

        var binding = await _binding.CaptureAsync();

        var payload = JsonSerializer.Serialize(new
        {
            endpoint = relativeEndpoint,
            method,
            body = jsonBody,
            timeoutMs
        });

        var script = """
            (async () => {
              const p = PAYLOAD;
              const controller = new AbortController();
              const timer = setTimeout(() => controller.abort('timeout'), p.timeoutMs);
              const started = performance.now();

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

              let dispatched = false;
              try {
                dispatched = true;
                const response = await fetch(p.endpoint, options);
                let text = await response.text();
                if (text.length > 750000) {
                  text = text.slice(0, 750000);
                }

                return {
                  ok: response.ok,
                  status: response.status,
                  text,
                  elapsedMs: Math.round(performance.now() - started),
                  dispatched,
                  error: null
                };
              } catch (error) {
                return {
                  ok: false,
                  status: 0,
                  text: '',
                  elapsedMs: Math.round(performance.now() - started),
                  dispatched,
                  error: String(error)
                };
              } finally {
                clearTimeout(timer);
              }
            })()
            """.Replace("PAYLOAD", payload);

        TransportScriptResult? response;
        try
        {
            var raw = await _browser.ExecuteScriptAsync(script);
            response = JsonSerializer.Deserialize<TransportScriptResult>(
                raw,
                new JsonSerializerOptions
                {
                    PropertyNameCaseInsensitive = true
                });
        }
        catch (Exception ex)
        {
            return BuildResult(
                semanticMutation
                    ? PrivateTransportOutcome.UnknownOutcome
                    : PrivateTransportOutcome.ConfirmedFailure,
                false,
                0,
                relativeEndpoint,
                string.Empty,
                0,
                ex.Message);
        }

        if (response is null)
        {
            return BuildResult(
                semanticMutation
                    ? PrivateTransportOutcome.UnknownOutcome
                    : PrivateTransportOutcome.ConfirmedFailure,
                false,
                0,
                relativeEndpoint,
                string.Empty,
                0,
                "Page-context fetch returned no result.");
        }

        if (!await _binding.IsCurrentAsync(binding))
        {
            return BuildResult(
                PrivateTransportOutcome.ContextInvalidated,
                false,
                response.Status,
                relativeEndpoint,
                response.Text ?? string.Empty,
                response.ElapsedMs,
                "WebView document/origin changed while the request was in flight.");
        }

        if (response.Status == 0)
        {
            return BuildResult(
                semanticMutation && response.Dispatched
                    ? PrivateTransportOutcome.UnknownOutcome
                    : PrivateTransportOutcome.ConfirmedFailure,
                false,
                0,
                relativeEndpoint,
                response.Text ?? string.Empty,
                response.ElapsedMs,
                response.Error);
        }

        return BuildResult(
            response.Ok
                ? PrivateTransportOutcome.ConfirmedSuccess
                : PrivateTransportOutcome.ConfirmedFailure,
            response.Ok,
            response.Status,
            relativeEndpoint,
            response.Text ?? string.Empty,
            response.ElapsedMs,
            response.Error);
    }

    private static PrivateTransportResult BuildResult(
        PrivateTransportOutcome outcome,
        bool ok,
        int status,
        string endpoint,
        string responseBody,
        long elapsedMs,
        string? error)
    {
        var bytes = Encoding.UTF8.GetBytes(responseBody);
        var hash = Convert.ToHexString(
                SHA256.HashData(bytes))
            .ToLowerInvariant();

        return new PrivateTransportResult(
            outcome,
            ok,
            status,
            ScheduledTaskTrafficFilter.SanitizeUrl(
                new Uri(new Uri("https://chatgpt.com"), endpoint).AbsoluteUri),
            JsonShape.Describe(responseBody),
            responseBody.Length,
            hash,
            elapsedMs,
            error,
            responseBody);
    }

    private static void ValidateEndpoint(string relativeEndpoint)
    {
        if (string.IsNullOrWhiteSpace(relativeEndpoint) ||
            !relativeEndpoint.StartsWith(
                "/backend-api/",
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Private transport is restricted to explicit /backend-api/ relative endpoints.");
        }

        if (relativeEndpoint.Contains(
                "://",
                StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Absolute URLs are not allowed in the private transport client.");
        }
    }

    private sealed class TransportScriptResult
    {
        public bool Ok { get; set; }
        public int Status { get; set; }
        public string? Text { get; set; }
        public long ElapsedMs { get; set; }
        public bool Dispatched { get; set; }
        public string? Error { get; set; }
    }
}
