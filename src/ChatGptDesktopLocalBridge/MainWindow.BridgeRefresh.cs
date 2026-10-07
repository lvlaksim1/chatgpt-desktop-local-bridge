using System.Windows;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private async void RefreshBridgeButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (ActiveTab is not { } tab)
        {
            return;
        }

        if (!tab.BridgeReady || tab.BridgeHost is null)
        {
            await EnsureBridgeForTabAsync(tab, automatic: false);
            return;
        }

        if (tab.ReadyCompletion is not null)
        {
            SetStatus("Local Bridge уже ожидает подтверждение модели.");
            return;
        }

        var composerReady = await WaitForBridgeComposerAsync(
            tab,
            TimeSpan.FromSeconds(12),
            CancellationToken.None);

        if (!composerReady)
        {
            SetStatus("Не удалось повторить инструкцию: поле ввода ChatGPT ещё не готово.");
            return;
        }

        var completion = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        tab.ReadyCompletion = completion;

        try
        {
            SetTabState(tab, "waiting");
            SetStatus("Повторная передача инструкции Local Bridge…");

            var sent = await TrySendBootstrapWithRetriesAsync(
                tab,
                tab.BridgeHost.CreateBootstrapMessage(),
                attempts: 2,
                CancellationToken.None);

            if (!sent)
            {
                throw new InvalidOperationException(
                    "ChatGPT не принял повторную инструкцию Local Bridge.");
            }

            await completion.Task.WaitAsync(TimeSpan.FromSeconds(60));

            tab.LastBootstrappedUrl =
                tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl;
            SetTabState(tab, "ready");
            SetStatus($"Инструкция моста обновлена · {tab.BridgeHost.SessionId[..8]}…");
        }
        catch (TimeoutException)
        {
            SetTabState(tab, "ready");
            SetStatus("Мост остаётся активным, но модель не подтвердила повторную инструкцию.");
        }
        catch (Exception ex)
        {
            SetTabState(tab, "ready");
            SetStatus($"Не удалось повторить инструкцию Local Bridge: {ex.Message}");
        }
        finally
        {
            if (ReferenceEquals(tab.ReadyCompletion, completion))
            {
                tab.ReadyCompletion = null;
            }
        }
    }
}