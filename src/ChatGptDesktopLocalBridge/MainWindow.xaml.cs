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

        VersionText.Text = LoadDisplayVersion();

        _appDataRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge");

        Loaded += async (_, _) => await InitializeWebViewAsync();
    }

    private static string LoadDisplayVersion()
    {
        try
        {
            var releaseInfoPath = Path.Combine(AppContext.BaseDirectory, "release-info.json");
            if (File.Exists(releaseInfoPath))
            {
                using var document = JsonDocument.Parse(File.ReadAllText(releaseInfoPath));
                if (document.RootElement.TryGetProperty("appVersion", out var versionElement) &&
                    versionElement.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrWhiteSpace(versionElement.GetString()))
                {
                    return $"v{versionElement.GetString()}";
                }
            }
        }
        catch
        {
            // Fall back to the assembly version for local/debug builds.
        }

        var assemblyVersion = typeof(MainWindow).Assembly.GetName().Version?.ToString();
        return $"v{assemblyVersion ?? "dev"}";
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
        StatusText.Text = "Загрузка ChatGPT…";
    }

    private void Browser_OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        StatusText.Text = e.IsSuccess
            ? "ChatGPT готов. При необходимости войдите в аккаунт, затем инициализируйте мост."
            : $"Ошибка навигации: {e.WebErrorStatus}";
    }

    private void CoreWebView2_OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            if (!IsAllowedOrigin(e.Source))
            {
                StatusText.Text = $"Сообщение из недоверенного источника проигнорировано: {e.Source}";
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

                    // WebView2 callbacks are serialized. Run the bridge loop only after this
                    // WebMessageReceived callback returns so a later send-result message can arrive.
                    Dispatcher.BeginInvoke(new Action(() => _ = HandleBridgeRequestAsync(requestCopy)));
                    return;
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Ошибка моста: {ex.Message}";
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
            StatusText.Text = $"Ошибка моста: {ex.Message}";
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
            _bridgeHost = new BridgeHost(
                policy,
                SendTextToChatAsync,
                message => Dispatcher.Invoke(() => StatusText.Text = message));

            readyCompletion = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            _bridgeReadyCompletion = readyCompletion;

            var bootstrap = _bridgeHost.CreateBootstrapMessage();
            var sent = await SendTextToChatAsync(bootstrap);
            if (!sent)
            {
                if (!StatusText.Text.StartsWith("Ошибка отправки в ChatGPT:", StringComparison.Ordinal))
                {
                    StatusText.Text =
                        "Не удалось отправить bootstrap моста. Откройте диалог и запустите диагностику.";
                }
                return;
            }

            StatusText.Text =
                $"Bootstrap отправлен. Ожидание подтверждения моста {_bridgeHost.SessionId[..8]}…";

            try
            {
                await readyCompletion.Task.WaitAsync(TimeSpan.FromSeconds(60));
                StatusText.Text =
                    $"Мост готов. Сессия {_bridgeHost.SessionId[..8]}…";
            }
            catch (TimeoutException)
            {
                StatusText.Text =
                    "Bootstrap отправлен, но ChatGPT не вернул ожидаемое подтверждение READY.";
            }
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Ошибка инициализации моста: {ex.Message}";
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
            StatusText.Text = "Диагностика недоступна: WebView2 ещё не готов.";
            return;
        }

        try
        {
            var raw = await Browser.ExecuteScriptAsync(
                "window.__localBridge?.health?.() ?? null");

            if (string.IsNullOrWhiteSpace(raw) || raw == "null")
            {
                StatusText.Text = "Ошибка диагностики: адаптер Local Bridge не внедрён.";
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
                $"Адаптер v{version}: WebView {(webViewAvailable ? "OK" : "ОШИБКА")}, " +
                $"поле ввода {(composerFound ? "OK" : "НЕ НАЙДЕНО")}, " +
                $"native input {(nativeInputReady ? "ГОТОВ" : "НЕ ГОТОВ")}.";

            var details = JsonSerializer.Serialize(
                root,
                new JsonSerializerOptions { WriteIndented = true });

            System.Windows.MessageBox.Show(
                details,
                "Диагностика Local Bridge",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Ошибка диагностики: {ex.Message}";
        }
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

                StatusText.Text = $"Ошибка отправки в ChatGPT: {reason}";
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
                StatusText.Text = "Ошибка отправки в ChatGPT: native-input-not-accepted";
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

                StatusText.Text = $"Ошибка отправки в ChatGPT: {reason}";
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

            StatusText.Text = "Ошибка отправки в ChatGPT: native-submit-not-confirmed";
            return false;
        }
        catch (Exception ex)
        {
            StatusText.Text = $"Ошибка отправки в ChatGPT: {ex.Message}";
            return false;
        }
    }
}
