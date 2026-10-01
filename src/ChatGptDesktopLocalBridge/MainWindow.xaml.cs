using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Core;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private readonly string _appDataRoot;
    private readonly ConcurrentDictionary<string, TaskCompletionSource<bool>> _pendingSendResults = new();
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

    private void CoreWebView2_OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
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

            if (!document.RootElement.TryGetProperty("type", out var typeElement))
            {
                return;
            }

            switch (typeElement.GetString())
            {
                case "bridge.send_result":
                    HandleSendResult(document.RootElement);
                    return;

                case "bridge.request":
                    if (!document.RootElement.TryGetProperty("request", out var requestElement) ||
                        _bridgeHost is null)
                    {
                        return;
                    }

                    var requestCopy = requestElement.Clone();

                    // WebView2 callbacks are serialized. Run the bridge loop only after this
                    // WebMessageReceived callback returns so a later send-result message can arrive.
                    Dispatcher.BeginInvoke(new Action(() => _ = HandleBridgeRequestAsync(requestCopy)));
                    return;
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Bridge error: {ex.Message}";
        }
    }

    private void HandleSendResult(JsonElement message)
    {
        if (!message.TryGetProperty("token", out var tokenElement) ||
            tokenElement.ValueKind != JsonValueKind.String ||
            string.IsNullOrWhiteSpace(tokenElement.GetString()))
        {
            return;
        }

        var token = tokenElement.GetString()!;
        var ok = message.TryGetProperty("ok", out var okElement) &&
                 okElement.ValueKind is JsonValueKind.True or JsonValueKind.False &&
                 okElement.GetBoolean();

        if (_pendingSendResults.TryRemove(token, out var completion))
        {
            completion.TrySetResult(ok);
        }

        if (!ok &&
            message.TryGetProperty("reason", out var reasonElement) &&
            reasonElement.ValueKind == JsonValueKind.String)
        {
            StatusText.Text = $"Chat send failed: {reasonElement.GetString()}";
        }
    }

    private async Task HandleBridgeRequestAsync(JsonElement request)
    {
        try
        {
            if (_bridgeHost is not null)
            {
                await _bridgeHost.HandleAsync(request);
            }
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
        var startInfo = new ProcessStartInfo("notepad.exe")
        {
            UseShellExecute = true
        };
        startInfo.ArgumentList.Add(path);
        Process.Start(startInfo);
    }

    private async Task<bool> SendTextToChatAsync(string text)
    {
        if (Browser.CoreWebView2 is null)
        {
            return false;
        }

        var token = Guid.NewGuid().ToString("N");
        var completion = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        if (!_pendingSendResults.TryAdd(token, completion))
        {
            return false;
        }

        try
        {
            var textArgument = JsonSerializer.Serialize(text);
            var tokenArgument = JsonSerializer.Serialize(token);
            var raw = await Browser.ExecuteScriptAsync(
                $"window.__localBridge?.sendText({textArgument}, {tokenArgument}) ?? {{accepted:false, reason:'adapter-not-ready'}}");

            if (string.IsNullOrWhiteSpace(raw))
            {
                return false;
            }

            using var document = JsonDocument.Parse(raw);
            var accepted = document.RootElement.TryGetProperty("accepted", out var acceptedElement) &&
                           acceptedElement.ValueKind is JsonValueKind.True or JsonValueKind.False &&
                           acceptedElement.GetBoolean();

            if (!accepted)
            {
                return false;
            }

            return await completion.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        catch (TimeoutException)
        {
            StatusText.Text = "Timed out waiting for ChatGPT send acknowledgement.";
            return false;
        }
        catch
        {
            return false;
        }
        finally
        {
            _pendingSendResults.TryRemove(token, out _);
        }
    }
}
