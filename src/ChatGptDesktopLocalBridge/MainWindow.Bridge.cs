using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ChatGptDesktopLocalBridge.Bridge;
using ChatGptDesktopLocalBridge.ScheduledTasks;
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

    private void ScheduleBridgeStart(
        ChatTab tab,
        TimeSpan delay)
    {
        tab.BridgeRetryCts?.Cancel();
        var cts = new CancellationTokenSource();
        tab.BridgeRetryCts = cts;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(delay, cts.Token);
                await Dispatcher.InvokeAsync(
                    () => _ = EnsureBridgeForTabAsync(
                        tab,
                        automatic: true,
                        cancellationToken: cts.Token));
            }
            catch (OperationCanceledException)
            {
            }
        });
    }

    private async Task EnsureBridgeForTabAsync(
        ChatTab tab,
        bool automatic,
        CancellationToken cancellationToken = default)
    {
        if (!tab.NavigationReady ||
            !tab.PageReady ||
            tab.Browser.CoreWebView2 is null)
        {
            return;
        }

        if (!ReferenceEquals(ActiveTab, tab) && automatic)
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

        SetTabState(tab, "waiting");

        if (ReferenceEquals(ActiveTab, tab))
        {
            SetStatus(automatic
                ? "Ожидание готовности Local Bridge…"
                : "Подготовка Local Bridge…");
        }

        var composerReady = await WaitForBridgeComposerAsync(
            tab,
            automatic ? TimeSpan.FromSeconds(30) : TimeSpan.FromSeconds(12),
            cancellationToken);

        if (!composerReady)
        {
            if (automatic)
            {
                tab.BridgeRetryCount++;
                SetTabState(tab, "waiting");

                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus("ChatGPT загружен; мост ждёт готовности поля ввода.");
                }

                if (tab.BridgeRetryCount <= 6)
                {
                    ScheduleBridgeStart(
                        tab,
                        TimeSpan.FromSeconds(
                            Math.Min(3 + tab.BridgeRetryCount * 2, 15)));
                }
            }
            else
            {
                SetTabState(tab, "error");
                SetStatus("Local Bridge: поле ввода ChatGPT ещё не готово.");
            }

            return;
        }

        var policy = PermissionPolicy.LoadOrCreate();
        var statusSink = new Action<string>(
            message => Dispatcher.BeginInvoke(new Action(() =>
            {
                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus(message);
                }
            })));
        var activitySink = new Action<BridgeActivityEvent>(
            activity => Dispatcher.BeginInvoke(
                new Action(() => OnBridgeActivity(tab, activity))));

        var conversationUri =
            tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl;
        var pendingDeliveries =
            await BridgeHost.GetPendingDeliveriesForConversationAsync(
                conversationUri,
                cancellationToken);

        if (pendingDeliveries.Count > 1)
        {
            SetTabState(tab, "error");
            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus(
                    "Восстановление Local Bridge заблокировано: для этого чата найдено несколько недоставленных результатов.");
            }
            return;
        }

        tab.BridgeHost?.Dispose();

        var localIntentPlanner = new LocalIntentPlanner(tab.Browser);

        if (pendingDeliveries.Count == 1)
        {
            var pending = pendingDeliveries[0];
            var recoveryHost = new BridgeHost(
                policy,
                text => SendTextToChatAsync(tab, text),
                statusSink,
                sessionId: pending.Session,
                confirmPermission: ConfirmBridgePermissionAsync,
                activity: activitySink,
                localIntentPlanner: localIntentPlanner.PlanAsync);

            tab.BridgeHost = recoveryHost;
            var resultAlreadyVisible =
                await HasBridgeResultInConversationAsync(
                    tab,
                    pending.Session,
                    pending.RequestId);

            await recoveryHost.RecoverPendingDeliveryAsync(
                pending,
                resultAlreadyVisible,
                cancellationToken);

            tab.BridgeReady = true;
            tab.BridgeRetryCount = 0;
            tab.LastBootstrappedUrl = conversationUri;
            SetTabState(tab, "ready");

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Мост восстановлен · {recoveryHost.SessionId[..8]}…");
            }

            return;
        }

        var host = new BridgeHost(
            policy,
            text => SendTextToChatAsync(tab, text),
            statusSink,
            confirmPermission: ConfirmBridgePermissionAsync,
            activity: activitySink,
            localIntentPlanner: localIntentPlanner.PlanAsync);

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

            var sent = await TrySendBootstrapWithRetriesAsync(
                tab,
                host.CreateBootstrapMessage(),
                automatic ? 4 : 2,
                cancellationToken);

            if (!sent)
            {
                throw new InvalidOperationException(
                    "ChatGPT не принял bootstrap после ожидания готовности.");
            }

            if (!automatic)
            {
                _settings.AutoInitializeBridge = true;
                _settings.Save();
            }

            await completion.Task.WaitAsync(
                TimeSpan.FromSeconds(60),
                cancellationToken);

            tab.BridgeReady = true;
            tab.BridgeRetryCount = 0;
            tab.LastBootstrappedUrl =
                tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl;

            SetTabState(tab, "ready");

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Мост готов · {host.SessionId[..8]}…");
            }
        }
        catch (OperationCanceledException)
        {
            tab.BridgeHost = null;
            tab.BridgeReady = false;
        }
        catch (TimeoutException)
        {
            tab.BridgeHost = null;
            tab.BridgeReady = false;
            SetTabState(tab, automatic ? "waiting" : "error");

            if (automatic)
            {
                tab.BridgeRetryCount++;

                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus("Мост не подтвердил READY; повторю автоматически.");
                }

                if (tab.BridgeRetryCount <= 6)
                {
                    ScheduleBridgeStart(
                        tab,
                        TimeSpan.FromSeconds(
                            Math.Min(4 + tab.BridgeRetryCount * 2, 16)));
                }
            }
            else if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus("Local Bridge: нет подтверждения READY.");
            }
        }
        catch (Exception ex)
        {
            tab.BridgeHost = null;
            tab.BridgeReady = false;
            SetTabState(tab, automatic ? "waiting" : "error");

            if (automatic)
            {
                tab.BridgeRetryCount++;

                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus("Local Bridge ещё не готов; повторю автоматически.");
                }

                if (tab.BridgeRetryCount <= 6)
                {
                    ScheduleBridgeStart(
                        tab,
                        TimeSpan.FromSeconds(
                            Math.Min(4 + tab.BridgeRetryCount * 2, 16)));
                }
            }
            else if (ReferenceEquals(ActiveTab, tab))
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

    private async Task<bool> WaitForBridgeComposerAsync(
        ChatTab tab,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow + timeout;

        while (DateTime.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();

            try
            {
                var raw = await tab.Browser.ExecuteScriptAsync(
                    """
                    (() => {
                      const health = window.__localBridge?.health?.();
                      const state = window.__localBridge?.nativeSendState?.();
                      return {
                        adapter: Boolean(health?.webViewAvailable),
                        nativeInputReady: Boolean(health?.nativeInputReady),
                        composerEmpty: Boolean(state?.composerEmpty)
                      };
                    })()
                    """);

                using var document = JsonDocument.Parse(raw);
                var root = document.RootElement;

                var adapter =
                    root.TryGetProperty("adapter", out var a) &&
                    a.ValueKind == JsonValueKind.True;
                var nativeReady =
                    root.TryGetProperty("nativeInputReady", out var n) &&
                    n.ValueKind == JsonValueKind.True;
                var composerEmpty =
                    root.TryGetProperty("composerEmpty", out var c) &&
                    c.ValueKind == JsonValueKind.True;

                if (adapter && nativeReady && composerEmpty)
                {
                    return true;
                }
            }
            catch
            {
            }

            await Task.Delay(250, cancellationToken);
        }

        return false;
    }

    private async Task<bool> TrySendBootstrapWithRetriesAsync(
        ChatTab tab,
        string bootstrap,
        int attempts,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; attempt <= attempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var outcome = await SendTextToChatAttemptAsync(tab, bootstrap);
            if (outcome == ChatSendOutcome.Confirmed)
            {
                return true;
            }

            if (outcome == ChatSendOutcome.UncertainAfterSubmit)
            {
                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus(
                        "Bootstrap: отправка началась, но подтверждение сообщения не получено; повтор не выполняю, ожидаю READY.");
                }

                // A non-idempotent composer submit may already have succeeded.
                // Treat it as possibly sent and let READY become the proof.
                return true;
            }

            if (attempt < attempts)
            {
                await Task.Delay(
                    TimeSpan.FromMilliseconds(500 * attempt),
                    cancellationToken);

                if (!await WaitForBridgeComposerAsync(
                        tab,
                        TimeSpan.FromSeconds(5),
                        cancellationToken))
                {
                    continue;
                }
            }
        }

        return false;
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
                    var requestSource = e.Source;
                    Dispatcher.BeginInvoke(
                        new Action(() =>
                            _ = tab.BridgeHost.HandleAsync(
                                requestCopy,
                                requestSource)));
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

    private Task<bool> ConfirmBridgePermissionAsync(
        BridgePermissionPrompt prompt)
    {
        if (Dispatcher.CheckAccess())
        {
            return Task.FromResult(
                ShowBridgePermissionPrompt(prompt));
        }

        return Dispatcher
            .InvokeAsync(() => ShowBridgePermissionPrompt(prompt))
            .Task;
    }

    private static bool ShowBridgePermissionPrompt(
        BridgePermissionPrompt prompt)
    {
        var result = MessageBox.Show(
            $"ChatGPT запрашивает локальное действие:\n\n{prompt.Capability}\n\n{prompt.Summary}\n\nРазрешить этот запрос один раз?",
            "Разрешение Local Bridge",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question,
            MessageBoxResult.No);

        return result == MessageBoxResult.Yes;
    }

    private void StopLocalTaskButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (ActiveTab?.BridgeHost is not { } host)
        {
            SetStatus("В активной вкладке нет запущенной сессии Local Bridge.");
            return;
        }

        var stop = host.StopActiveWork();
        SetStatus(!stop.CancellationRequested &&
                  stop.StoppedProcesses == 0 &&
                  stop.StoppedTerminals == 0
            ? "Сейчас нет выполняющегося локального действия."
            : $"STOP отправлен · отмена={(stop.CancellationRequested ? "да" : "нет")} · процессов={stop.StoppedProcesses} · терминалов={stop.StoppedTerminals}");
    }

    private async Task<bool> HasBridgeResultInConversationAsync(
        ChatTab tab,
        string session,
        string requestId)
    {
        if (tab.Browser.CoreWebView2 is null)
        {
            return false;
        }

        var sessionArgument = JsonSerializer.Serialize(session);
        var requestIdArgument = JsonSerializer.Serialize(requestId);
        var raw = await tab.Browser.ExecuteScriptAsync(
            $"window.__localBridge?.hasResult?.({sessionArgument}, {requestIdArgument}) ?? false");

        using var document = JsonDocument.Parse(raw);
        return document.RootElement.ValueKind == JsonValueKind.True;
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

    private enum ChatSendOutcome
    {
        Confirmed,
        RejectedBeforeSubmit,
        UncertainAfterSubmit
    }

    private async Task<bool> SendTextToChatAsync(
        ChatTab tab,
        string text)
        => await SendTextToChatAttemptAsync(tab, text) ==
           ChatSendOutcome.Confirmed;

    private async Task<ChatSendOutcome> SendTextToChatAttemptAsync(
        ChatTab tab,
        string text)
    {
        var browser = tab.Browser;
        var submissionStarted = false;

        if (browser.CoreWebView2 is null)
        {
            return ChatSendOutcome.RejectedBeforeSubmit;
        }

        try
        {
            var baselineRaw = await browser.ExecuteScriptAsync(
                "window.__localBridge?.nativeSendReceipt?.(null, 0)?.userMessageCount ?? null");

            if (string.IsNullOrWhiteSpace(baselineRaw) ||
                baselineRaw == "null")
            {
                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus("Ошибка отправки: send-receipt-unavailable");
                }
                return ChatSendOutcome.RejectedBeforeSubmit;
            }

            using var baselineDocument = JsonDocument.Parse(baselineRaw);
            if (baselineDocument.RootElement.ValueKind != JsonValueKind.Number ||
                !baselineDocument.RootElement.TryGetInt32(
                    out var baselineUserMessageCount))
            {
                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus("Ошибка отправки: send-receipt-invalid");
                }
                return ChatSendOutcome.RejectedBeforeSubmit;
            }

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
                return ChatSendOutcome.RejectedBeforeSubmit;
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
                return ChatSendOutcome.RejectedBeforeSubmit;
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
                return ChatSendOutcome.RejectedBeforeSubmit;
            }

            submissionStarted = true;
            var sendDeadline = DateTime.UtcNow.AddSeconds(30);

            while (DateTime.UtcNow < sendDeadline)
            {
                var receiptRaw = await browser.ExecuteScriptAsync(
                    $"window.__localBridge?.nativeSendReceipt?.({expectedArgument}, {baselineUserMessageCount}) ?? null");

                if (!string.IsNullOrWhiteSpace(receiptRaw) &&
                    receiptRaw != "null")
                {
                    using var receiptDocument = JsonDocument.Parse(receiptRaw);
                    var receipt = receiptDocument.RootElement;

                    var confirmed =
                        receipt.TryGetProperty(
                            "confirmed",
                            out var confirmedElement) &&
                        confirmedElement.ValueKind == JsonValueKind.True;

                    if (confirmed)
                    {
                        return ChatSendOutcome.Confirmed;
                    }
                }

                await Task.Delay(100);
            }

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus(
                    "Отправка началась, но появление нового сообщения не подтверждено; автоматический повтор заблокирован.");
            }

            return ChatSendOutcome.UncertainAfterSubmit;
        }
        catch (Exception ex)
        {
            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Ошибка отправки: {ex.Message}");
            }

            return submissionStarted
                ? ChatSendOutcome.UncertainAfterSubmit
                : ChatSendOutcome.RejectedBeforeSubmit;
        }
    }

}