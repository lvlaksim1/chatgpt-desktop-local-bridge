using System.Windows;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private async Task CheckForUpdatesAsync()
    {
        try
        {
            var candidate = await UpdateService.CheckAsync();
            if (candidate is null)
            {
                return;
            }

            _availableUpdate = candidate;

            await Dispatcher.InvokeAsync(() =>
            {
                UpdateButton.Content = "Обновить";
                UpdateButton.ToolTip =
                    $"Доступно обновление {candidate.CurrentTag} → {candidate.TargetTag}";
                UpdateButton.Visibility = Visibility.Visible;
            });
        }
        catch
        {
            // Update checks are intentionally non-blocking.
        }
    }

    private async void UpdateButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (_availableUpdate is null)
        {
            _ = CheckForUpdatesAsync();
            return;
        }

        var candidate = _availableUpdate;

        var answer = MessageBox.Show(
            $"Установить обновление {candidate.TargetTag}?\n\n" +
            "Файл будет скачан напрямую из GitHub, проверен по SHA-256 и запущен без браузера.",
            "Обновление ChatGPT Desktop Local Bridge",
            MessageBoxButton.YesNo,
            MessageBoxImage.Question);

        if (answer != MessageBoxResult.Yes)
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

            SetStatus("Обновление проверено. Запуск установщика…");
            SaveRuntimeSettings();

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
