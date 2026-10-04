using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.PrivateTransport;

public sealed record PrivateTransportResponse(
    bool Ok,
    int Status,
    string Path,
    string ResponseSchema,
    int ResponseLength,
    long ElapsedMs,
    string? Error,
    string? Body);

public sealed class ChatGptPrivateTransport
{
    private const int MaxResponseChars = 500_000;
    private readonly WebView2 _browser;
    private long _navigationGeneration;

    public ChatGptPrivateTransport(WebView2 browser)
    {
        _browser = browser;
        _browser.NavigationStarting += (_, _) =>
            Interlocked.Increment(ref _navigationGeneration);
    }

    public RequestBinding CaptureBinding()
    {
        var source = _browser.Source;
        if (source is null ||
            source.Scheme != Uri.UriSchemeHttps ||
            !(source.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
              source.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidOperationException(
                "Private transport requires an active https://chatgpt.com document.");
        }

        return new RequestBinding(
            source.GetLeftPart(UriPartial.Authority),
            Interlocked.Read(ref _navigationGeneration));
    }

    public async Task<PrivateTransportResponse> SendReadAsync(
        RequestBinding binding,
        string relativePath,
        string method = "GET",
        string? jsonBody = null)
    {
        binding.Validate(_browser, Interlocked.Read(ref _navigationGeneration));

        method = method.ToUpperInvariant();
        if (method is not ("GET" or "HEAD" or "POST"))
        {
            throw new InvalidOperationException(
                "Read-only private transport permits GET, HEAD, or known read-only POST.");
        }

        if (!relativePath.StartsWith("/backend-api/", StringComparison.Ordinal) ||
            relativePath.Contains("://", StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "Only relative /backend-api/ paths are allowed.");
        }

        var payload = JsonSerializer.Serialize(new
        {
            path = relativePath,
            method,
            body = jsonBody,
            max = MaxResponseChars
        });

        var script = """
            (async () => {
              const p = PAYLOAD;
              const started = performance.now();
              const options = {
                method: p.method,
                credentials: 'include',
                redirect: 'follow',
                headers: { 'accept': 'application/json, text/plain, */*' }
              };
              if (p.body !== null) {
                options.headers['content-type'] = 'application/json';
                options.body = p.body;
              }
              try {
                const r = await fetch(p.path, options);
                let text = await r.text();
                if (text.length > p.max) text = text.slice(0, p.max);
                return {
                  ok: r.ok,
                  status: r.status,
                  path: new URL(r.url).pathname,
                  text,
                  elapsedMs: Math.round(performance.now() - started),
                  error: null
                };
              } catch (e) {
                return {
                  ok: false,
                  status: 0,
                  path: p.path,
                  text: '',
                  elapsedMs: Math.round(performance.now() - started),
                  error: String(e)
                };
              }
            })()
            """.Replace("PAYLOAD", payload);

        var raw = await _browser.ExecuteScriptAsync(script);
        var result = JsonSerializer.Deserialize<ScriptResult>(
            raw,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("Private transport returned no result.");

        binding.Validate(_browser, Interlocked.Read(ref _navigationGeneration));

        var body = result.Text ?? string.Empty;
        return new PrivateTransportResponse(
            result.Ok,
            result.Status,
            result.Path ?? relativePath,
            ScheduledTasks.JsonShape.Describe(body),
            body.Length,
            result.ElapsedMs,
            result.Error,
            body);
    }

    private sealed class ScriptResult
    {
        public bool Ok { get; set; }
        public int Status { get; set; }
        public string? Path { get; set; }
        public string? Text { get; set; }
        public long ElapsedMs { get; set; }
        public string? Error { get; set; }
    }
}

public sealed record RequestBinding(
    string Origin,
    long NavigationGeneration)
{
    public void Validate(WebView2 browser, long currentGeneration)
    {
        var source = browser.Source;
        if (source is null ||
            !string.Equals(
                source.GetLeftPart(UriPartial.Authority),
                Origin,
                StringComparison.OrdinalIgnoreCase) ||
            currentGeneration != NavigationGeneration)
        {
            throw new InvalidOperationException(
                "STALE_CONTEXT: WebView origin or navigation generation changed.");
        }
    }
}
