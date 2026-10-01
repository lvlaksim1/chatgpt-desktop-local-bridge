using System.Diagnostics;
using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Core;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private readonly string _appDataRoot;
    private BridgeHost? _bridgeHost;

    public MainWindow()
    {
        InitializeComponent();

        _appDataRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge");

        Loaded += async (_, _) => await InitializeWebViewAsync();
    }

    private async Task InitializeWebViewAsync()
    {
        Directory.CreateDirectory(_appDataRoot);

        var userDataFolder = Path.Combine(_appDataRoot, "WebView2");
        var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: userDataFolder);
        await Browser.EnsureCoreWebView2Async(environment);

        Browser.CoreWebView2.Settings.IsWebMessageEnabled = true;
        Browser.CoreWebView2.Settings.AreDevToolsEnabled = true;

        var policy = PermissionPolicy.LoadOrCreate();
        _bridgeHost = new BridgeHost(
            policy,
            SendTextToChatAsync,
            message => Dispatcher.Invoke(() => StatusText.Text = message));

        Browser.CoreWebView2.WebMessageReceived += CoreWebView2_OnWebMessageReceived;
        Browser.NavigationCompleted += Browser_OnNavigationCompleted;

        var adapterPath = Path.Combine(AppContext.BaseDirectory, "Web", "bridge-adapter.js");
        var adapterScript = await File.ReadAllTextAsync(adapterPath);
        await Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(adapterScript);

        Browser.Source = new Uri("https://chatgpt.com/");
        StatusText.Text = "ChatGPT loading…";
    }

    private void Browser_OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        StatusText.Text = e.IsSuccess
            ? "ChatGPT ready. Sign in if necessary, then initialize the bridge."
            : $"Navigation failed: {e.WebErrorStatus}";
    }

    private async void CoreWebView2_OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            if (!IsAllowedOrigin(e.Source))
            {
                StatusText.Text = $"Ignored message from untrusted origin: {e.Source}";
                return;
            }

            var json = e.WebMessageAsJson;
            using var document = JsonDocument.Parse(json);

            if (!document.RootElement.TryGetProperty("type", out var typeElement) ||
                typeElement.GetString() != "bridge.request")
            {
                return;
            }

            if (!document.RootElement.TryGetProperty("request", out var requestElement))
            {
                return;
            }

            if (_bridgeHost is null)
            {
                return;
            }

            await _bridgeHost.HandleAsync(requestElement);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Bridge error: {ex.Message}";
        }
    }

    private static bool IsAllowedOrigin(string source)
    {
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri))
        {
            return false;
        }

        return uri.Scheme == Uri.UriSchemeHttps &&
               (uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
                uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase));
    }

    private async void InitializeBridgeButton_OnClick(object sender, System.Windows.RoutedEventArgs e)
    {
        if (_bridgeHost is null)
        {
            return;
        }

        var bootstrap = _bridgeHost.CreateBootstrapMessage();
        var sent = await SendTextToChatAsync(bootstrap);
        StatusText.Text = sent
            ? $"Bridge initialized. Session {_bridgeHost.SessionId[..8]}…"
            : "Could not find the ChatGPT composer. Open a conversation and try again.";
    }

    private void ReloadButton_OnClick(object sender, System.Windows.RoutedEventArgs e)
        => Browser.Reload();

    private void PermissionsButton_OnClick(object sender, System.Windows.RoutedEventArgs e)
    {
        var path = PermissionPolicy.GetUserPolicyPath();
        Process.Start(new ProcessStartInfo("notepad.exe", $""{path}"")
        {
            UseShellExecute = true
        });
    }

    private async Task<bool> SendTextToChatAsync(string text)
    {
        if (Browser.CoreWebView2 is null)
        {
            return false;
        }

        var argument = JsonSerializer.Serialize(text);
        var raw = await Browser.ExecuteScriptAsync(
            $"window.__localBridge?.sendText({argument}) ?? Promise.resolve({{ok:false, reason:'adapter-not-ready'}})");

        if (string.IsNullOrWhiteSpace(raw))
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(raw);
            return document.RootElement.TryGetProperty("ok", out var ok) && ok.GetBoolean();
        }
        catch
        {
            return false;
        }
    }
}
