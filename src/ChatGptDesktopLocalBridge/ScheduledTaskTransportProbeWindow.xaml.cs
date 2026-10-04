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
    private readonly ScheduledTaskNetworkProbe _networkProbe;
    private readonly ScheduledTaskProbeProfile _profile;
    private readonly DispatcherTimer _refreshTimer;
    private int _lastTrafficCount = -1;

    public ScheduledTaskTransportProbeWindow(WebView2 browser)
    {
        if (browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException("The active ChatGPT tab is not initialized.");
        }

        InitializeComponent();

        _networkProbe = new ScheduledTaskNetworkProbe(browser.CoreWebView2);
        _profile = ScheduledTaskProbeProfile.Load();

        PayloadTextBox.Text =
            "PING-" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();

        _refreshTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(400)
        };
        _refreshTimer.Tick += (_, _) => RefreshTraffic();

        Loaded += async (_, _) =>
        {
            UpdateProfileStatus();
            _refreshTimer.Start();
            await StartCaptureAsync();
        };

        Closed += async (_, _) =>
        {
            _refreshTimer.Stop();
            await _networkProbe.DisposeAsync();
        };
    }

    private async void CaptureButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (_networkProbe.IsRunning)
        {
            await _networkProbe.StopAsync();
            CaptureButton.Content = "Capture: OFF";
            CaptureStatusText.Text = "Сбор остановлен";
        }
        else
        {
            await StartCaptureAsync();
        }
    }

    private async Task StartCaptureAsync()
    {
        try
        {
            await _networkProbe.StartAsync();
            CaptureButton.Content = "Capture: ON";
            CaptureStatusText.Text =
                $"Сбор включён · {Path.GetFileName(_networkProbe.LogPath)}";
        }
        catch (Exception ex)
        {
            CaptureButton.Content = "Capture: ERROR";
            CaptureStatusText.Text = ex.Message;
        }
    }

    private void ClearTrafficButton_OnClick(object sender, RoutedEventArgs e)
    {
        _networkProbe.Clear();
        _lastTrafficCount = -1;
        TrafficDetailTextBox.Clear();
        RefreshTraffic();
    }

    private void OpenLogButton_OnClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var directory = Path.GetDirectoryName(_networkProbe.LogPath)!;
            Directory.CreateDirectory(directory);
            Process.Start(new ProcessStartInfo("explorer.exe", directory)
            {
                UseShellExecute = true
            });
        }
        catch (Exception ex)
        {
            SetOperationStatus("ERROR", ex.Message);
        }
    }

    private void RefreshTraffic()
    {
        var snapshot = _networkProbe.Snapshot();
        if (snapshot.Count == _lastTrafficCount)
        {
            return;
        }

        TrafficList.ItemsSource = snapshot;
        _lastTrafficCount = snapshot.Count;

        if (snapshot.Count > 0)
        {
            TrafficList.SelectedIndex = snapshot.Count - 1;
            TrafficList.ScrollIntoView(TrafficList.SelectedItem);
        }
    }

    private void TrafficList_OnSelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (TrafficList.SelectedItem is not ScheduledTaskTrafficEntry entry)
        {
            TrafficDetailTextBox.Clear();
            return;
        }

        TrafficDetailTextBox.Text = JsonSerializer.Serialize(
            new
            {
                entry.Sequence,
                entry.TimestampUtc,
                entry.Method,
                entry.Url,
                entry.RequestBody,
                entry.Status,
                entry.MimeType,
                entry.ResponseBody,
                entry.Error
            },
            new JsonSerializerOptions { WriteIndented = true });
    }

    private void LearnListButton_OnClick(object sender, RoutedEventArgs e)
        => LearnSelected("LIST", null);

    private void LearnGetButton_OnClick(object sender, RoutedEventArgs e)
        => LearnSelected("GET", MailboxTaskIdTextBox.Text.Trim());

    private void LearnUpdateButton_OnClick(object sender, RoutedEventArgs e)
        => LearnSelected("UPDATE", MailboxTaskIdTextBox.Text.Trim());

    private void LearnArmButton_OnClick(object sender, RoutedEventArgs e)
        => LearnSelected("ARM", WorkerTaskIdTextBox.Text.Trim());

    private void LearnSelected(string kind, string? sourceTaskId)
    {
        try
        {
            if (TrafficList.SelectedItem is not ScheduledTaskTrafficEntry entry)
            {
                throw new InvalidOperationException("Сначала выберите captured request.");
            }

            if (kind != "LIST" && string.IsNullOrWhiteSpace(sourceTaskId))
            {
                throw new InvalidOperationException(
                    "Укажите Task ID, который использовался в выбранном запросе.");
            }

            var template = new ScheduledTaskRequestTemplate(
                kind,
                entry.Method,
                ScheduledTaskProbeSanitizer.CreateUrlTemplate(
                    entry.ReplayUrl,
                    sourceTaskId),
                ScheduledTaskProbeSanitizer.CreateBodyTemplate(
                    entry.RequestBody,
                    sourceTaskId),
                sourceTaskId,
                DateTimeOffset.UtcNow);

            switch (kind)
            {
                case "LIST": _profile.List = template; break;
                case "GET": _profile.Get = template; break;
                case "UPDATE": _profile.Update = template; break;
                case "ARM": _profile.Arm = template; break;
            }

            _profile.Save();
            UpdateProfileStatus();
            SetOperationStatus("LEARNED", $"{kind}: {entry.Method} {entry.Url}");
        }
        catch (Exception ex)
        {
            SetOperationStatus("ERROR", ex.Message);
        }
    }

    private void UpdateProfileStatus()
    {
        ProfileStatusText.Text =
            $"L:{Flag(_profile.List)} G:{Flag(_profile.Get)} U:{Flag(_profile.Update)} A:{Flag(_profile.Arm)}";
    }

    private static string Flag(ScheduledTaskRequestTemplate? value)
        => value is null ? "—" : "✓";

    private void SetOperationStatus(string state, string detail)
    {
        OperationStatusText.Text = $"Статус: {state} · {detail}";
    }

    private void ListTasksButton_OnClick(object sender, RoutedEventArgs e)
        => SetOperationStatus("PROTOCOL", "Сначала захватите и выучите LIST запрос.");

    private void ReadMailboxButton_OnClick(object sender, RoutedEventArgs e)
        => SetOperationStatus("PROTOCOL", "Сначала захватите и выучите GET запрос.");

    private void WriteReadyButton_OnClick(object sender, RoutedEventArgs e)
        => SetOperationStatus("PROTOCOL", "Сначала захватите и выучите UPDATE запрос.");

    private void ArmWorkerButton_OnClick(object sender, RoutedEventArgs e)
        => SetOperationStatus("PROTOCOL", "Сначала захватите и выучите ARM запрос.");

    private void ReadAckButton_OnClick(object sender, RoutedEventArgs e)
        => SetOperationStatus("PROTOCOL", "После discovery будет включён программный ACK probe.");
}
