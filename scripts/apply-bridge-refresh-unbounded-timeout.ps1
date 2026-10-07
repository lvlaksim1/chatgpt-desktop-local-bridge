$ErrorActionPreference = 'Stop'

$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Read-Text([string]$Path) {
    return [System.IO.File]::ReadAllText($Path)
}

function Write-Text([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Replace-Exact([string]$Path, [string]$Old, [string]$New) {
    $text = Read-Text $Path
    if ($text.Contains($New)) {
        return
    }
    if (-not $text.Contains($Old)) {
        throw "Expected text not found in $Path"
    }
    Write-Text $Path ($text.Replace($Old, $New))
}

# The visible 'Мост' button now refreshes the existing model instruction when the bridge is already ready.
Replace-Exact `
    'src/ChatGptDesktopLocalBridge/MainWindow.xaml' `
    'Click="InitializeBridgeButton_OnClick"' `
    'Click="RefreshBridgeButton_OnClick"'

$refreshPath = 'src/ChatGptDesktopLocalBridge/MainWindow.BridgeRefresh.cs'
$refreshSource = @'
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
'@
Write-Text $refreshPath $refreshSource

# process.run: 120 seconds remains the default. 0 means no timeout. There is no positive hard ceiling.
$toolRouter = 'src/ChatGptDesktopLocalBridge/Bridge/ToolRouter.cs'
Replace-Exact $toolRouter `
    '    private const int MaxProcessTimeoutMs = 900_000;' `
    ''
Replace-Exact $toolRouter `
    '                "{ \"file\": \"git.exe\", \"arguments\": [\"status\"], \"cwd\": \"C:/repo\", \"timeout_ms\": 120000, \"max_output_chars\": 200000 }",' `
    '                "{ \"file\": \"git.exe\", \"arguments\": [\"status\"], \"cwd\": \"C:/repo\", \"timeout_ms\": 0, \"max_output_chars\": 200000 }",'

$oldTimeout = @'
        var timeoutMs = Math.Clamp(
            OptionalInt(args, "timeout_ms", DefaultProcessTimeoutMs),
            1_000,
            MaxProcessTimeoutMs);
'@
$newTimeout = @'
        var timeoutMs = OptionalInt(
            args,
            "timeout_ms",
            DefaultProcessTimeoutMs);
        if (timeoutMs < 0)
        {
            throw new BridgeToolException(
                "invalid_args",
                "timeout_ms must be 0 (unlimited) or a positive number of milliseconds.");
        }
'@
Replace-Exact $toolRouter $oldTimeout $newTimeout

$processManager = 'src/ChatGptDesktopLocalBridge/Bridge/ProcessExecutionManager.cs'
$oldCts = '            using var timeoutCts = new CancellationTokenSource(spec.TimeoutMs);'
$newCts = @'
            using var timeoutCts = spec.TimeoutMs > 0
                ? new CancellationTokenSource(spec.TimeoutMs)
                : new CancellationTokenSource();
'@
Replace-Exact $processManager $oldCts $newCts.TrimEnd("`r", "`n")

# The updater must target the version currently installed by the owner.
Replace-Exact `
    '.github/workflows/local-bridge-runnow-v1-release.yml' `
    '  BASE_TAG: private-transport-v5-95dd011' `
    '  BASE_TAG: local-bridge-runnow-de8284e'

Write-Host 'Bridge refresh and unbounded process timeout patch applied.'
