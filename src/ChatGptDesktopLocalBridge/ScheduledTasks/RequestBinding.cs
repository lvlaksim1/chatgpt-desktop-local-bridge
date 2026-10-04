using System.Text.Json;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record PrivateTransportBinding(
    string Origin,
    string DocumentToken,
    string PageUrl,
    DateTimeOffset CapturedUtc);

public sealed class RequestBinding
{
    private readonly WebView2 _browser;

    public RequestBinding(WebView2 browser)
    {
        _browser = browser;
    }

    public async Task<PrivateTransportBinding> CaptureAsync()
    {
        EnsureReady();

        var raw = await _browser.ExecuteScriptAsync(
            """
            (() => {
              const key = '__local_bridge_private_transport_document_token_v1';
              if (!window[key]) {
                const random = globalThis.crypto?.randomUUID
                  ? globalThis.crypto.randomUUID()
                  : (Date.now().toString(16) + '-' + Math.random().toString(16).slice(2));
                Object.defineProperty(window, key, {
                  value: random,
                  writable: false,
                  configurable: false,
                  enumerable: false
                });
              }

              return {
                origin: location.origin,
                documentToken: window[key],
                pageUrl: location.href
              };
            })()
            """);

        var snapshot = JsonSerializer.Deserialize<BindingScriptResult>(
            raw,
            new JsonSerializerOptions
            {
                PropertyNameCaseInsensitive = true
            }) ?? throw new InvalidOperationException(
                "Could not capture WebView request binding.");

        if (!string.Equals(
                snapshot.Origin,
                "https://chatgpt.com",
                StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"Private transport requires https://chatgpt.com origin; current origin is '{snapshot.Origin}'.");
        }

        if (string.IsNullOrWhiteSpace(snapshot.DocumentToken) ||
            string.IsNullOrWhiteSpace(snapshot.PageUrl))
        {
            throw new InvalidOperationException(
                "WebView binding did not return a document token and page URL.");
        }

        return new PrivateTransportBinding(
            snapshot.Origin!,
            snapshot.DocumentToken!,
            snapshot.PageUrl!,
            DateTimeOffset.UtcNow);
    }

    public async Task<bool> IsCurrentAsync(
        PrivateTransportBinding expected)
    {
        var current = await CaptureAsync();

        return string.Equals(
                   current.Origin,
                   expected.Origin,
                   StringComparison.OrdinalIgnoreCase) &&
               string.Equals(
                   current.DocumentToken,
                   expected.DocumentToken,
                   StringComparison.Ordinal);
    }

    private void EnsureReady()
    {
        if (_browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException(
                "The active ChatGPT WebView is not initialized.");
        }
    }

    private sealed class BindingScriptResult
    {
        public string? Origin { get; set; }
        public string? DocumentToken { get; set; }
        public string? PageUrl { get; set; }
    }
}
