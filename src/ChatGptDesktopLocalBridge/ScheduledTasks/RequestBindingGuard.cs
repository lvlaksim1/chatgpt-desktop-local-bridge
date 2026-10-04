using System.Security.Cryptography;
using System.Text;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record RequestBinding(
    string Origin,
    string DocumentUri,
    string DocumentFingerprint,
    long NavigationGeneration)
{
    public string Display =>
        $"{Origin} · nav={NavigationGeneration} · doc={DocumentFingerprint[..12]}";
}

public sealed class RequestBindingGuard
{
    private readonly WebView2 _browser;
    private long _navigationGeneration;

    public RequestBindingGuard(WebView2 browser)
    {
        _browser = browser;
        _browser.NavigationStarting += (_, _) =>
            Interlocked.Increment(ref _navigationGeneration);
    }

    public RequestBinding Capture()
    {
        var uriText = _browser.Source?.AbsoluteUri
            ?? throw new InvalidOperationException("WebView has no active document URI.");

        var uri = new Uri(uriText);
        if (!uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !(uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
              uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidOperationException(
                "Private transport is restricted to an active chatgpt.com document.");
        }

        var documentFingerprint = Convert.ToHexString(
                SHA256.HashData(Encoding.UTF8.GetBytes(uri.GetLeftPart(UriPartial.Path))))
            .ToLowerInvariant();

        return new RequestBinding(
            uri.GetLeftPart(UriPartial.Authority),
            uriText,
            documentFingerprint,
            Interlocked.Read(ref _navigationGeneration));
    }

    public void Validate(RequestBinding binding)
    {
        var current = Capture();

        if (!string.Equals(binding.Origin, current.Origin, StringComparison.OrdinalIgnoreCase) ||
            binding.NavigationGeneration != current.NavigationGeneration ||
            !string.Equals(binding.DocumentFingerprint, current.DocumentFingerprint, StringComparison.Ordinal))
        {
            throw new InvalidOperationException(
                "STALE_CONTEXT: ChatGPT document/navigation changed while the private backend operation was running.");
        }
    }
}
