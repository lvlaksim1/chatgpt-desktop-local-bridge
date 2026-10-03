using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Core;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private async void InitializeBridgeButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (ActiveTab is not { } tab)
        {
            return;
        }

        await EnsureBridgeForTabAsync(tab, automatic: false);
    }

    private async Task EnsureBridgeForTabAsync(
        ChatTab tab,
        bool automatic)
    {
        if (!tab.NavigationReady ||
            tab.Browser.CoreWebView2 is null)
        {
            return;
        }

        if (tab.BridgeReady && tab.BridgeHost is not null)
        {
            if (!automatic && ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Мост уже готов · {tab.BridgeHost.SessionId[..8]}…");
            }
            return;
        }

        if (tab.ReadyCompletion is not null)
        {
            return;
        }

        var policy = PermissionPolicy.LoadOrCreate();
        var host = new BridgeHost(
            policy,
            text => SendTextToChatAsync(tab, text),
            message => Dispatcher.BeginInvoke(new Action(() =>
            {
                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus(message);
                }
            })),
            activity => Dispatcher.BeginInvoke(
                new Action(() => OnBridgeActivity(tab, activity))));

        tab.BridgeHost = host;
        tab.BridgeReady = false;
        tab.ReadyCompletion = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var completion = tab.ReadyCompletion;

        try
        {
            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus(automatic
                    ? "Автовосстановление Local Bridge…"
                    : "Инициализация Local Bridge…");
            }

            var sent = await SendTextToChatAsync(
                tab,
                host.CreateBootstrapMessage());

            if (!sent)
            {
                throw new InvalidOperationException(
                    "Не удалось отправить bootstrap Local Bridge.");
            }

            if (!automatic)
            {
                _settings.AutoInitializeBridge = true;
                _settings.Save();
            }

            await completion.Task.WaitAsync(TimeSpan.FromSeconds(60));

            tab.BridgeReady = true;
            tab.LastBootstrappedUrl =
                tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl;

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Мост готов · {host.SessionId[..8]}…");
            }
        }
        catch (TimeoutException)
        {
            tab.BridgeHost = null;
            tab.BridgeReady = false;

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus("Local Bridge: нет подтверждения READY.");
            }
        }
        catch (Exception ex)
        {
            tab.BridgeHost = null;
            tab.BridgeReady = false;

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Ошибка Local Bridge: {ex.Message}");
            }
        }
        finally
        {
            if (ReferenceEquals(tab.ReadyCompletion, completion))
            {
                tab.ReadyCompletion = null;
            }
        }
    }

    private void CoreWebView2_OnWebMessageReceived(
        ChatTab tab,
        CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            if (!IsAllowedOrigin(e.Source))
            {
                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus($"Недоверенный источник: {e.Source}");
                }
                return;
            }

            using var document = JsonDocument.Parse(e.WebMessageAsJson);
            var root = document.RootElement;

            if (!root.TryGetProperty("type", out var typeElement))
            {
                return;
            }

            switch (typeElement.GetString())
            {
                case "bridge.ready":
                    if (tab.BridgeHost is null ||
                        !root.TryGetProperty("session", out var sessionElement) ||
                        sessionElement.ValueKind != JsonValueKind.String ||
                        !string.Equals(
                            sessionElement.GetString(),
                            tab.BridgeHost.SessionId,
                            StringComparison.Ordinal))
                    {
                        return;
                    }

                    tab.ReadyCompletion?.TrySetResult(true);
                    return;

                case "bridge.request":
                    if (tab.BridgeHost is null ||
                        !root.TryGetProperty("request", out var requestElement))
                    {
                        return;
                    }

                    var requestCopy = requestElement.Clone();
                    Dispatcher.BeginInvoke(
                        new Action(() =>
                            _ = tab.BridgeHost.HandleAsync(requestCopy)));
                    return;
            }
        }
        catch (Exception ex)
        {
            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Ошибка моста: {ex.Message}");
            }
        }
    }

    private static bool IsAllowedOrigin(string source)
    {
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri))
        {
            return false;
        }

        return uri.Scheme == Uri.UriSchemeHttps &&
               (uri.Host.Equals(
                    "chatgpt.com",
                    StringComparison.OrdinalIgnoreCase) ||
                uri.Host.EndsWith(
                    ".chatgpt.com",
                    StringComparison.OrdinalIgnoreCase));
    }

    private void OnBridgeActivity(
        ChatTab tab,
        BridgeActivityEvent activity)
    {
        var phase = activity.Phase switch
        {
            "received" => "получен",
            "running" => "выполняется",
            "completed" => "готов",
            "failed" => "ошибка",
            "delivery_failed" => "ошибка доставки",
            _ => activity.Phase
        };

        var requestShort = activity.RequestId.Length > 18
            ? activity.RequestId[..18] + "…"
            : activity.RequestId;

        var suffix = activity.ElapsedMs.HasValue
            ? $" · {activity.ElapsedMs.Value} мс"
            : string.Empty;

        var text =
            $"{activity.Timestamp.ToLocalTime():HH:mm:ss}  " +
            $"{activity.Tool} · {requestShort} · {phase}{suffix}";

        if (!ReferenceEquals(ActiveTab, tab))
        {
            text = $"[{tab.HeaderText.Text}] {text}";
        }

        var block = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)FindResource("PanelTextBrush"),
            Margin = new Thickness(2, 2, 2, 4)
        };

        ActivityList.Items.Add(block);

        while (ActivityList.Items.Count > 300)
        {
            ActivityList.Items.RemoveAt(0);
        }

        ActivityList.ScrollIntoView(block);

        if (activity.Tool == "process.run")
        {
            AppendProcessActivityToConsole(tab, activity);
        }
    }

    private void AppendProcessActivityToConsole(
        ChatTab tab,
        BridgeActivityEvent activity)
    {
        if (activity.Phase == "running")
        {
            var file = TryGetString(activity.Args, "file") ?? "?";
            var arguments = new List<string>();

            if (activity.Args.ValueKind == JsonValueKind.Object &&
                activity.Args.TryGetProperty("arguments", out var argsElement) &&
                argsElement.ValueKind == JsonValueKind.Array)
            {
                arguments.AddRange(
                    argsElement.EnumerateArray()
                        .Select(item => item.GetString() ?? string.Empty));
            }

            var cwd = TryGetString(activity.Args, "cwd");
            var command = file +
                          (arguments.Count > 0
                              ? " " + string.Join(
                                  " ",
                                  arguments.Select(QuoteArgument))
                              : string.Empty);

            AppendConsole(
                $"{activity.Timestamp.ToLocalTime():HH:mm:ss} " +
                $"[{tab.HeaderText.Text}] > {command}\r\n" +
                (string.IsNullOrWhiteSpace(cwd)
                    ? string.Empty
                    : $"cwd: {cwd}\r\n"));

            return;
        }

        if (activity.Phase == "completed" &&
            activity.Result is JsonElement result)
        {
            var exitCode = TryGetValue(result, "exitCode");
            var elapsed = TryGetValue(result, "elapsedMs");
            var timedOut = TryGetValue(result, "timedOut");
            var stdout = TryGetString(result, "stdout");
            var stderr = TryGetString(result, "stderr");

            var builder = new StringBuilder();
            builder.AppendLine(
                $"exit={exitCode ?? "?"} elapsed={elapsed ?? "?"}ms timeout={timedOut ?? "false"}");

            if (!string.IsNullOrEmpty(stdout))
            {
                builder.AppendLine("--- stdout ---");
                builder.AppendLine(stdout.TrimEnd());
            }

            if (!string.IsNullOrEmpty(stderr))
            {
                builder.AppendLine("--- stderr ---");
                builder.AppendLine(stderr.TrimEnd());
            }

            builder.AppendLine();
            AppendConsole(builder.ToString());
            return;
        }

        if (activity.Phase is "failed" or "delivery_failed")
        {
            AppendConsole(
                $"ERROR {activity.ErrorCode}: {activity.ErrorMessage}\r\n\r\n");
        }
    }

    private void AppendConsole(string text)
    {
        ConsoleTextBox.AppendText(text);

        if (ConsoleTextBox.Text.Length > 200_000)
        {
            ConsoleTextBox.Text =
                ConsoleTextBox.Text[^150_000..];
        }

        ConsoleTextBox.ScrollToEnd();
    }

    private static string? TryGetString(
        JsonElement element,
        string name)
    {
        if (element.ValueKind == JsonValueKind.Object &&
            element.TryGetProperty(name, out var value) &&
            value.ValueKind == JsonValueKind.String)
        {
            return value.GetString();
        }

        return null;
    }

    private static string? TryGetValue(
        JsonElement element,
        string name)
    {
        if (element.ValueKind != JsonValueKind.Object ||
            !element.TryGetProperty(name, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.ToString(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => value.ToString()
        };
    }

    private static string QuoteArgument(string value)
    {
        return value.Any(char.IsWhiteSpace)
            ? "\"" + value.Replace("\"", "\\\"") + "\""
            : value;
    }

    private async Task<bool> SendTextToChatAsync(
        ChatTab tab,
        string text)
    {
        var browser = tab.Browser;

        if (browser.CoreWebView2 is null)
        {
            return false;
        }

        try
        {
            var preflightRaw = await browser.ExecuteScriptAsync(
                "window.__localBridge?.prepareNativeSend?.() ?? {accepted:false, reason:'adapter-not-ready'}");

            using var preflightDocument = JsonDocument.Parse(preflightRaw);
            var preflight = preflightDocument.RootElement;

            var accepted =
                preflight.TryGetProperty("accepted", out var acceptedElement) &&
                acceptedElement.ValueKind is JsonValueKind.True or JsonValueKind.False &&
                acceptedElement.GetBoolean();

            if (!accepted)
            {
                var reason =
                    preflight.TryGetProperty("reason", out var reasonElement) &&
                    reasonElement.ValueKind == JsonValueKind.String
                        ? reasonElement.GetString()
                        : "composer-preflight-failed";

                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus($"Ошибка отправки: {reason}");
                }

                return false;
            }

            var insertParameters = JsonSerializer.Serialize(new { text });
            await browser.CoreWebView2.CallDevToolsProtocolMethodAsync(
                "Input.insertText",
                insertParameters);

            var expectedArgument = JsonSerializer.Serialize(text);
            var insertionDeadline = DateTime.UtcNow.AddSeconds(5);
            var inserted = false;

            while (DateTime.UtcNow < insertionDeadline)
            {
                var stateRaw = await browser.ExecuteScriptAsync(
                    $"window.__localBridge?.nativeSendState?.({expectedArgument}) ?? null");

                if (!string.IsNullOrWhiteSpace(stateRaw) &&
                    stateRaw != "null")
                {
                    using var stateDocument = JsonDocument.Parse(stateRaw);
                    var state = stateDocument.RootElement;

                    inserted =
                        state.TryGetProperty(
                            "textMatches",
                            out var matchesElement) &&
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
                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus("Ошибка отправки: native-input-not-accepted");
                }

                return false;
            }

            var submitRaw = await browser.ExecuteScriptAsync(
                "window.__localBridge?.submitNativeSend?.() ?? {accepted:false, reason:'adapter-not-ready'}");

            using var submitDocument = JsonDocument.Parse(submitRaw);
            var submit = submitDocument.RootElement;

            var submitAccepted =
                submit.TryGetProperty(
                    "accepted",
                    out var submitAcceptedElement) &&
                submitAcceptedElement.ValueKind is
                    JsonValueKind.True or JsonValueKind.False &&
                submitAcceptedElement.GetBoolean();

            if (!submitAccepted)
            {
                var reason =
                    submit.TryGetProperty("reason", out var reasonElement) &&
                    reasonElement.ValueKind == JsonValueKind.String
                        ? reasonElement.GetString()
                        : "native-submit-rejected";

                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus($"Ошибка отправки: {reason}");
                }

                return false;
            }

            var sendDeadline = DateTime.UtcNow.AddSeconds(8);

            while (DateTime.UtcNow < sendDeadline)
            {
                var stateRaw = await browser.ExecuteScriptAsync(
                    "window.__localBridge?.nativeSendState?.() ?? null");

                if (!string.IsNullOrWhiteSpace(stateRaw) &&
                    stateRaw != "null")
                {
                    using var stateDocument = JsonDocument.Parse(stateRaw);
                    var state = stateDocument.RootElement;

                    var composerEmpty =
                        state.TryGetProperty(
                            "composerEmpty",
                            out var emptyElement) &&
                        emptyElement.ValueKind == JsonValueKind.True;

                    if (composerEmpty)
                    {
                        return true;
                    }
                }

                await Task.Delay(100);
            }

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus("Ошибка отправки: native-submit-not-confirmed");
            }

            return false;
        }
        catch (Exception ex)
        {
            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Ошибка отправки: {ex.Message}");
            }

            return false;
        }
    }
}
