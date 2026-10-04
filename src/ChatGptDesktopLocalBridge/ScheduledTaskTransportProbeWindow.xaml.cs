using System.Diagnostics;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using ChatGptDesktopLocalBridge.ScheduledTasks;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge;

public partial class ScheduledTaskTransportProbeWindow
{
    private readonly ScheduledTaskMetadataProbe _probe;
    private readonly DispatcherTimer _refreshTimer;
    private int _lastCount = -1;

    public ScheduledTaskTransportProbeWindow(WebView2 browser)
    {
        if (browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException(
                "The active ChatGPT tab is not initialized.");
        }

        InitializeComponent();

        _probe = new ScheduledTaskMetadataProbe(browser.CoreWebView2);
        _refreshTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(400)
        };
        _refreshTimer.Tick += (_, _) => RefreshTraffic();

        Loaded += async (_, _) =>
        {
            _refreshTimer.Start();
            await StartCaptureAsync();
        };

        Closed += async (_, _) =>
        {
            _refreshTimer.Stop();
            await _probe.DisposeAsync();
        };
    }

    private async void CaptureButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (_probe.IsRunning)
        {
            await _probe.StopAsync();
            CaptureButton.Content = "Capture: OFF";
            CaptureStatusText.Text = "Сбор остановлен";
            return;
        }

        await StartCaptureAsync();
    }

    private async Task StartCaptureAsync()
    {
        try
        {
            await _probe.StartAsync();
            CaptureButton.Content = "Capture: ON";
            CaptureStatusText.Text =
                $"Сбор включён · {Path.GetFileName(_probe.LogPath)}";
        }
        catch (Exception ex)
        {
            CaptureButton.Content = "Capture: ERROR";
            CaptureStatusText.Text = ex.Message;
        }
    }

    private void ClearButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        _probe.Clear();
        _lastCount = -1;
        DetailTextBox.Clear();
        RefreshTraffic();
        SetStatus("CLEARED", "Список очищен; файл лога сохранён.");
    }

    private void OpenLogButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        try
        {
            var directory = Path.GetDirectoryName(_probe.LogPath)!;
            Directory.CreateDirectory(directory);

            Process.Start(
                new ProcessStartInfo("explorer.exe", directory)
                {
                    UseShellExecute = true
                });
        }
        catch (Exception ex)
        {
            SetStatus("ERROR", ex.Message);
        }
    }

    private void CopySelectedButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (TrafficList.SelectedItem is not ScheduledTaskTrafficEntry entry)
        {
            SetStatus("ERROR", "Сначала выберите request.");
            return;
        }

        Clipboard.SetText($"{entry.Method} {entry.Url}");
        SetStatus("COPIED", $"{entry.Method} {entry.Url}");
    }

    private void MarkerButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string label })
        {
            return;
        }

        var marker = new
        {
            type = "ui-action-marker",
            timestampUtc = DateTimeOffset.UtcNow,
            label,
            mailboxTaskId = NormalizeId(MailboxTaskIdTextBox.Text),
            workerTaskId = NormalizeId(WorkerTaskIdTextBox.Text)
        };

        try
        {
            File.AppendAllText(
                _probe.LogPath,
                JsonSerializer.Serialize(marker) + Environment.NewLine);

            SetStatus(
                "MARK",
                $"{label} · {DateTimeOffset.Now:HH:mm:ss.fff}");
        }
        catch (Exception ex)
        {
            SetStatus("ERROR", ex.Message);
        }
    }

    private void RefreshTraffic()
    {
        var snapshot = _probe.Snapshot();
        if (snapshot.Count == _lastCount)
        {
            return;
        }

        var selectedSequence =
            (TrafficList.SelectedItem as ScheduledTaskTrafficEntry)?.Sequence;

        TrafficList.ItemsSource = snapshot;
        _lastCount = snapshot.Count;

        if (selectedSequence.HasValue)
        {
            TrafficList.SelectedItem = snapshot.FirstOrDefault(
                item => item.Sequence == selectedSequence.Value);
        }

        if (TrafficList.SelectedItem is null && snapshot.Count > 0)
        {
            TrafficList.SelectedIndex = snapshot.Count - 1;
            TrafficList.ScrollIntoView(TrafficList.SelectedItem);
        }

        CaptureStatusText.Text =
            _probe.IsRunning
                ? $"Capture ON · candidates={snapshot.Count}"
                : $"Capture OFF · candidates={snapshot.Count}";
    }

    private void TrafficList_OnSelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (TrafficList.SelectedItem is not ScheduledTaskTrafficEntry entry)
        {
            DetailTextBox.Clear();
            return;
        }

        DetailTextBox.Text = JsonSerializer.Serialize(
            entry,
            new JsonSerializerOptions { WriteIndented = true });
    }

    private void SetStatus(string state, string detail)
    {
        OperationStatusText.Text =
            $"Статус: {state} · {detail}";
    }

    private static string? NormalizeId(string? value)
    {
        var trimmed = value?.Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return null;
        }

        return trimmed.Length <= 12
            ? trimmed
            : trimmed[..6] + "…" + trimmed[^4..];
    }
}
