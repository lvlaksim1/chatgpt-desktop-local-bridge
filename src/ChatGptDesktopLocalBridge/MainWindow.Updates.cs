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
                Math.Clamp(_settings.UpdateCheckIntervalMinutes, 5, 1440))
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

                UpdateButton.Content =
                    candidate.PackageKind == UpdatePackageKind.Delta
                        ? "Обновить"
                        : "Полный Setup";

                UpdateButton.ToolTip =
                    $"{candidate.CurrentTag} → {candidate.TargetTag}\n{candidate.Reason}";

                UpdateButton.Visibility = Visibility.Visible;

                if (!quiet)
                {
                    SetStatus(
                        candidate.PackageKind == UpdatePackageKind.Delta
                            ? "Доступно обновление."
                            : "Доступно обновление; требуется полный Setup.");
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
        if (_availableUpdate is null)
        {
            await CheckForUpdatesAsync(quiet: false);
            return;
        }

        var candidate = _availableUpdate;
        var window = new UpdateWindow(candidate) { Owner = this };

        if (window.ShowDialog() != true ||
            !window.InstallRequested)
        {
            return;
        }

        UpdateButton.IsEnabled = false;

        try
        {
            var progress = new Progress<double>(value =>
            {
                SetStatus($"Скачивание обновления: {value:P0}");
            });

            var path = await UpdateService.DownloadAndVerifyAsync(
                candidate,
                progress);

            UpdateService.MarkPending(candidate);
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
            UpdateButton.IsEnabled = true;
            SetStatus($"Ошибка обновления: {ex.Message}");

            MessageBox.Show(
                ex.Message,
                "Ошибка обновления",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }
}
