using System.Diagnostics;
using System.Text.Json;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Core;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private readonly string _appDataRoot;
    private TaskCompletionSource<bool>? _bridgeReadyCompletion;
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
                case "bridge.ready":
                    HandleBridgeReady(document.RootElement);
                    return;

                case "bridge.request":
                    if (!document.RootElement.TryGetProperty("request", out var requestElement) ||
                        _bridgeHost is null)
                    {
                        return;
                    }

                    var requestCopy = requestElement.Clone();
                    var requestSource = e.Source;

                    // WebView2 callbacks are serialized. Run the bridge loop only after this
                    // WebMessageReceived callback returns so a later send-result message can arrive.
                    Dispatcher.BeginInvoke(
                        new Action(() => _ = HandleBridgeRequestAsync(requestCopy, requestSource)));
                    return;
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Bridge error: {ex.Message}";
        }
    }

    private void HandleBridgeReady(JsonElement message)
    {
        if (_bridgeHost is null ||
            !message.TryGetProperty("session", out var sessionElement) ||
            sessionElement.ValueKind != JsonValueKind.String)
        {
            return;
        }

        var session = sessionElement.GetString();
        if (!string.Equals(session, _bridgeHost.SessionId, StringComparison.Ordinal))
        {
            return;
        }

        _bridgeReadyCompletion?.TrySetResult(true);
    }

    private async Task HandleBridgeRequestAsync(
        JsonElement request,
        string? conversationUri)
    {
        try
        {
            if (_bridgeHost is not null)
            {
                await _bridgeHost.HandleAsync(request, conversationUri);
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
        InitializeBridgeButton.IsEnabled = false;
        TaskCompletionSource<bool>? readyCompletion = null;

        try
        {
            var policy = PermissionPolicy.LoadOrCreate();
            var statusSink = new Action<string>(
                message => Dispatcher.Invoke(() => StatusText.Text = message));

            var currentConversationUri = Browser.Source?.AbsoluteUri;
            var pendingDeliveries =
                await BridgeHost.GetPendingDeliveriesForConversationAsync(currentConversationUri);

            if (pendingDeliveries.Count > 1)
            {
                StatusText.Text =
                    "Bridge recovery is blocked: multiple pending results exist for this conversation.";
                return;
            }

            if (pendingDeliveries.Count == 1)
            {
                var pending = pendingDeliveries[0];

                _bridgeHost = new BridgeHost(
                    policy,
                    SendTextToChatAsync,
                    statusSink,
                    pending.Session);

                var resultAlreadyVisible =
                    await HasBridgeResultInCurrentConversationAsync(
                        pending.Session,
                        pending.RequestId);

                await _bridgeHost.RecoverPendingDeliveryAsync(
                    pending,
                    resultAlreadyVisible);

                StatusText.Text =
                    $"Bridge resumed. Session {_bridgeHost.SessionId[..8]}…";
                return;
            }

            _bridgeHost = new BridgeHost(
                policy,
                SendTextToChatAsync,
                statusSink);

            readyCompletion = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            _bridgeReadyCompletion = readyCompletion;

            var bootstrap = _bridgeHost.CreateBootstrapMessage();
            var sent = await SendTextToChatAsync(bootstrap);
            if (!sent)
            {
                if (!StatusText.Text.StartsWith("Chat send failed:", StringComparison.Ordinal))
                {
                    StatusText.Text =
                        "Could not send bridge bootstrap. Open a conversation and run Diagnostics.";
                }
                return;
            }

            StatusText.Text =
                $"Bootstrap sent. Waiting for bridge handshake {_bridgeHost.SessionId[..8]}…";

            try
            {
                await readyCompletion.Task.WaitAsync(TimeSpan.FromSeconds(60));
                StatusText.Text =
                    $"Bridge ready. Session {_bridgeHost.SessionId[..8]}…";
            }
            catch (TimeoutException)
            {
                StatusText.Text =
                    "Bridge bootstrap was sent, but ChatGPT did not return the expected READY handshake.";
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Bridge initialization failed: {ex.Message}";
        }
        finally
        {
            if (ReferenceEquals(_bridgeReadyCompletion, readyCompletion))
            {
                _bridgeReadyCompletion = null;
            }

            InitializeBridgeButton.IsEnabled = true;
        }
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

    private async void DiagnosticsButton_OnClick(object sender, System.Windows.RoutedEventArgs e)
    {
        if (Browser.CoreWebView2 is null)
        {
            StatusText.Text = "Diagnostics unavailable: WebView2 is not ready.";
            return;
        }

        try
        {
            var raw = await Browser.ExecuteScriptAsync(
                "window.__localBridge?.health?.() ?? null");

            if (string.IsNullOrWhiteSpace(raw) || raw == "null")
            {
                StatusText.Text = "Diagnostics failed: Local Bridge adapter is not injected.";
                return;
            }

            using var document = JsonDocument.Parse(raw);
            var root = document.RootElement;

            var version = root.TryGetProperty("version", out var versionElement)
                ? versionElement.ToString()
                : "?";
            var composerFound = root.TryGetProperty("composerFound", out var composerElement) &&
                                composerElement.ValueKind == JsonValueKind.True;
            var nativeInputReady = root.TryGetProperty("nativeInputReady", out var nativeInputElement) &&
                                   nativeInputElement.ValueKind == JsonValueKind.True;
            var webViewAvailable = root.TryGetProperty("webViewAvailable", out var webViewElement) &&
                                   webViewElement.ValueKind == JsonValueKind.True;

            StatusText.Text =
                $"Adapter v{version}: WebView {(webViewAvailable ? "OK" : "FAIL")}, " +
                $"composer {(composerFound ? "OK" : "NOT FOUND")}, " +
                $"native input {(nativeInputReady ? "READY" : "NOT READY")}.";

            var details = JsonSerializer.Serialize(
                root,
                new JsonSerializerOptions { WriteIndented = true });

            System.Windows.MessageBox.Show(
                details,
                "Local Bridge diagnostics",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Diagnostics failed: {ex.Message}";
        }
    }

    private async Task<bool> HasBridgeResultInCurrentConversationAsync(
        string session,
        string requestId)
    {
        if (Browser.CoreWebView2 is null)
        {
            return false;
        }

        var sessionArgument = JsonSerializer.Serialize(session);
        var requestIdArgument = JsonSerializer.Serialize(requestId);

        var raw = await Browser.ExecuteScriptAsync(
            $"window.__localBridge?.hasResult?.({sessionArgument}, {requestIdArgument}) ?? false");

        using var document = JsonDocument.Parse(raw);
        return document.RootElement.ValueKind == JsonValueKind.True;
    }

    private async Task<bool> SendTextToChatAsync(string text)
    {
        if (Browser.CoreWebView2 is null)
        {
            return false;
        }

        try
        {
            var preflightRaw = await Browser.ExecuteScriptAsync(
                "window.__localBridge?.prepareNativeSend?.() ?? {accepted:false, reason:'adapter-not-ready'}");

            using var preflightDocument = JsonDocument.Parse(preflightRaw);
            var preflight = preflightDocument.RootElement;

            var accepted = preflight.TryGetProperty("accepted", out var acceptedElement) &&
                           acceptedElement.ValueKind is JsonValueKind.True or JsonValueKind.False &&
                           acceptedElement.GetBoolean();

            if (!accepted)
            {
                var reason = preflight.TryGetProperty("reason", out var reasonElement) &&
                             reasonElement.ValueKind == JsonValueKind.String
                    ? reasonElement.GetString()
                    : "composer-preflight-failed";

                StatusText.Text = $"Chat send failed: {reason}";
                return false;
            }

            var insertParameters = JsonSerializer.Serialize(new { text });
            await Browser.CoreWebView2.CallDevToolsProtocolMethodAsync(
                "Input.insertText",
                insertParameters);

            var expectedArgument = JsonSerializer.Serialize(text);
            var insertionDeadline = DateTime.UtcNow.AddSeconds(5);
            var inserted = false;

            while (DateTime.UtcNow < insertionDeadline)
            {
                var stateRaw = await Browser.ExecuteScriptAsync(
                    $"window.__localBridge?.nativeSendState?.({expectedArgument}) ?? null");

                if (!string.IsNullOrWhiteSpace(stateRaw) && stateRaw != "null")
                {
                    using var stateDocument = JsonDocument.Parse(stateRaw);
                    var state = stateDocument.RootElement;
                    inserted = state.TryGetProperty("textMatches", out var matchesElement) &&
                               matchesElement.ValueKind == JsonValueKind.True;

                    if (inserted)
                    {
                        break;
                    }
                }

                await Task.Delay(100);
            }

            if (!inserted)
            {
                StatusText.Text = "Chat send failed: native-input-not-accepted";
                return false;
            }

            var submitRaw = await Browser.ExecuteScriptAsync(
                "window.__localBridge?.submitNativeSend?.() ?? {accepted:false, reason:'adapter-not-ready'}");

            using var submitDocument = JsonDocument.Parse(submitRaw);
            var submit = submitDocument.RootElement;
            var submitAccepted =
                submit.TryGetProperty("accepted", out var submitAcceptedElement) &&
                submitAcceptedElement.ValueKind is JsonValueKind.True or JsonValueKind.False &&
                submitAcceptedElement.GetBoolean();

            if (!submitAccepted)
            {
                var reason = submit.TryGetProperty("reason", out var reasonElement) &&
                             reasonElement.ValueKind == JsonValueKind.String
                    ? reasonElement.GetString()
                    : "native-submit-rejected";

                StatusText.Text = $"Chat send failed: {reason}";
                return false;
            }

            var sendDeadline = DateTime.UtcNow.AddSeconds(8);
            while (DateTime.UtcNow < sendDeadline)
            {
                var stateRaw = await Browser.ExecuteScriptAsync(
                    "window.__localBridge?.nativeSendState?.() ?? null");

                if (!string.IsNullOrWhiteSpace(stateRaw) && stateRaw != "null")
                {
                    using var stateDocument = JsonDocument.Parse(stateRaw);
                    var state = stateDocument.RootElement;
                    var composerEmpty =
                        state.TryGetProperty("composerEmpty", out var emptyElement) &&
                        emptyElement.ValueKind == JsonValueKind.True;

                    if (composerEmpty)
                    {
                        return true;
                    }
                }

                await Task.Delay(100);
            }

            StatusText.Text = "Chat send failed: native-submit-not-confirmed";
            return false;
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Chat send failed: {ex.Message}";
            return false;
        }
    }

}
