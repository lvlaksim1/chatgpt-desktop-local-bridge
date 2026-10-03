using System.Windows;
using System.Windows.Threading;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private void StartUpdatePolling()
    {
        _updateTimer?.Stop();

        _updateTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMinutes(
                Math.Clamp(
                    _settings.UpdateCheckIntervalMinutes,
                    5,
                    1440))
        };

        _updateTimer.Tick += async (_, _) =>
            await CheckForUpdatesAsync(quiet: true);

        _updateTimer.Start();
    }

    private async Task CheckForUpdatesAsync(bool quiet)
    {
        try
        {
            var candidate = await UpdateService.CheckAsync();
            _availableUpdate = candidate;

            await Dispatcher.InvokeAsync(() =>
            {
                if (candidate is null)
                {
                    UpdateButton.Visibility = Visibility.Collapsed;

                    if (!quiet)
                    {
                        SetStatus("Установлена актуальная версия.");
                    }

                    return;
                }

                if (candidate.PackageKind != UpdatePackageKind.Delta)
                {
                    UpdateButton.Visibility = Visibility.Collapsed;

                    if (!quiet)
                    {
                        SetStatus(
                            "Для этого обновления требуется полный Setup: Настройки → Обновления.");
                    }

                    return;
                }

                UpdateButton.Content = "Обновить";
                UpdateButton.ToolTip =
                    $"{candidate.CurrentTag} → {candidate.TargetTag}\n{candidate.Reason}";
                UpdateButton.Visibility = Visibility.Visible;

                if (!quiet)
                {
                    SetStatus("Доступно delta-обновление.");
                }
            });
        }
        catch (Exception ex)
        {
            if (!quiet)
            {
                await Dispatcher.InvokeAsync(() =>
                    SetStatus($"Проверка обновлений: {ex.Message}"));
            }
        }
    }

    private async void UpdateButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (_availableUpdate is null ||
            _availableUpdate.PackageKind != UpdatePackageKind.Delta)
        {
            await CheckForUpdatesAsync(quiet: false);
            return;
        }

        await InstallCandidateAsync(
            _availableUpdate,
            disableTopUpdateButton: true);
    }

    private async Task InstallLatestFullSetupFromSettingsAsync()
    {
        try
        {
            SetStatus("Поиск полного Setup…");

            var candidate =
                await UpdateService.GetLatestFullSetupAsync();

            if (candidate is null)
            {
                SetStatus("Полный Setup не найден.");

                MessageBox.Show(
                    "В последнем UI-релизе не найден полный Setup.",
                    "Обновления",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);

                return;
            }

            await InstallCandidateAsync(
                candidate,
                disableTopUpdateButton: false);
        }
        catch (Exception ex)
        {
            SetStatus($"Ошибка полного Setup: {ex.Message}");

            MessageBox.Show(
                ex.Message,
                "Ошибка обновления",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private async Task InstallCandidateAsync(
        UpdateCandidate candidate,
        bool disableTopUpdateButton)
    {
        var window = new UpdateWindow(candidate)
        {
            Owner = this
        };

        if (window.ShowDialog() != true ||
            !window.InstallRequested)
        {
            return;
        }

        if (disableTopUpdateButton)
        {
            UpdateButton.IsEnabled = false;
        }

        try
        {
            var progress = new Progress<double>(value =>
            {
                SetStatus(
                    candidate.PackageKind == UpdatePackageKind.Delta
                        ? $"Скачивание delta-update: {value:P0}"
                        : $"Скачивание полного Setup: {value:P0}");
            });

            var path = await UpdateService.DownloadAndVerifyAsync(
                candidate,
                progress);

            if (!string.Equals(
                    candidate.CurrentTag,
                    candidate.TargetTag,
                    StringComparison.Ordinal))
            {
                UpdateService.MarkPending(candidate);
            }

            SaveRuntimeSettings();

            SetStatus(
                candidate.PackageKind == UpdatePackageKind.Delta
                    ? "Delta-update проверен. Запуск установки…"
                    : "Полный Setup проверен. Запуск установки…");

            UpdateService.StartInstaller(path);
            Application.Current.Shutdown();
        }
        catch (Exception ex)
        {
            if (disableTopUpdateButton)
            {
                UpdateButton.IsEnabled = true;
            }

            SetStatus($"Ошибка обновления: {ex.Message}");

            MessageBox.Show(
                ex.Message,
                "Ошибка обновления",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }
}
