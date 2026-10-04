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
    private readonly PageContextBackendReplay _replay;
    private readonly DispatcherTimer _refreshTimer;

    private int _lastSnapshotCount = -1;
    private string _filter = "ALL";

    public ScheduledTaskTransportProbeWindow(WebView2 browser)
    {
        if (browser.CoreWebView2 is null)
        {
            throw new InvalidOperationException(
                "The active ChatGPT tab is not initialized.");
        }

        InitializeComponent();

        _probe = new ScheduledTaskMetadataProbe(browser.CoreWebView2);
        _replay = new PageContextBackendReplay(browser);

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
                $"Capture ON · {Path.GetFileName(_probe.LogPath)}";
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
        _lastSnapshotCount = -1;
        DetailTextBox.Clear();
        ReplayEndpointTextBox.Clear();
        ReplayBodyTextBox.Clear();
        ReplayResultTextBox.Clear();
        RefreshTraffic();
        SetStatus("CLEARED", "Список очищен; предыдущий JSONL сохранён.");
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
            label
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

    private void KindFilterComboBox_OnSelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (KindFilterComboBox.SelectedItem is ComboBoxItem { Tag: string tag })
        {
            _filter = tag;
            _lastSnapshotCount = -1;
            RefreshTraffic();
        }
    }

    private void RefreshTraffic()
    {
        var snapshot = _probe.Snapshot();
        var filtered = snapshot
            .Where(MatchesFilter)
            .ToArray();

        if (snapshot.Count == _lastSnapshotCount &&
            TrafficList.Items.Count == filtered.Length)
        {
            return;
        }

        var selectedSequence =
            (TrafficList.SelectedItem as ScheduledTaskTrafficEntry)?.Sequence;

        TrafficList.ItemsSource = filtered;
        _lastSnapshotCount = snapshot.Count;

        if (selectedSequence.HasValue)
        {
            TrafficList.SelectedItem = filtered.FirstOrDefault(
                item => item.Sequence == selectedSequence.Value);
        }

        if (TrafficList.SelectedItem is null && filtered.Length > 0)
        {
            TrafficList.SelectedIndex = filtered.Length - 1;
            TrafficList.ScrollIntoView(TrafficList.SelectedItem);
        }

        var taskCount = snapshot.Count(
            item => item.Kind == BackendProbeKind.ScheduledTasks);
        var libraryCount = snapshot.Count(
            item => item.Kind == BackendProbeKind.Library);

        CaptureStatusText.Text =
            $"{(_probe.IsRunning ? "Capture ON" : "Capture OFF")} · tasks={taskCount} · library={libraryCount}";
    }

    private bool MatchesFilter(ScheduledTaskTrafficEntry entry)
        => _filter switch
        {
            "TASKS" => entry.Kind == BackendProbeKind.ScheduledTasks,
            "LIBRARY" => entry.Kind == BackendProbeKind.Library,
            _ => true
        };

    private void TrafficList_OnSelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (TrafficList.SelectedItem is not ScheduledTaskTrafficEntry entry)
        {
            DetailTextBox.Clear();
            ReplayEndpointTextBox.Clear();
            ReplayBodyTextBox.Clear();
            return;
        }

        DetailTextBox.Text = JsonSerializer.Serialize(
            new
            {
                entry.Sequence,
                entry.TimestampUtc,
                kind = entry.Kind.ToString(),
                entry.Method,
                entry.Url,
                entry.RequestSchema,
                entry.Status,
                entry.MimeType,
                entry.ResponseSchema,
                entry.Error
            },
            new JsonSerializerOptions { WriteIndented = true });

        ReplayEndpointTextBox.Text = $"{entry.Method} {entry.Url}";
        ReplayBodyTextBox.Text = entry.RequestBody ?? string.Empty;
    }

    private async void ReplaySelectedButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        if (TrafficList.SelectedItem is not ScheduledTaskTrafficEntry entry)
        {
            SetStatus("ERROR", "Сначала выберите captured request.");
            return;
        }

        var method = entry.Method.Trim().ToUpperInvariant();
        var isMutation = method is "POST" or "PUT" or "PATCH" or "DELETE";

        if (isMutation)
        {
            var decision = MessageBox.Show(
                this,
                "Будет повторён реально захваченный изменяющий запрос через текущую авторизованную WebView2-сессию.\n\n" +
                $"Kind: {entry.Kind}\nMethod: {method}\nEndpoint: {entry.Url}\n\n" +
                "Request body берётся только из памяти и может быть отредактирован в поле окна. " +
                "Продолжить?",
                "Experimental backend mutation replay",
                MessageBoxButton.YesNo,
                MessageBoxImage.Warning,
                MessageBoxResult.No);

            if (decision != MessageBoxResult.Yes)
            {
                SetStatus("CANCELLED", "Mutation replay отменён.");
                return;
            }
        }

        try
        {
            ReplayButton.IsEnabled = false;
            SetStatus(
                "REPLAY",
                $"{entry.Kind} · {entry.Method} · same-session page-context fetch");

            var result = await _replay.ExecuteAsync(
                entry,
                ReplayBodyTextBox.Text,
                ExpectedTextBox.Text.Trim());

            ReplayResultTextBox.Text = JsonSerializer.Serialize(
                result,
                new JsonSerializerOptions { WriteIndented = true });

            var expectedText = ExpectedTextBox.Text.Trim();
            var proof =
                string.IsNullOrWhiteSpace(expectedText)
                    ? "no marker check"
                    : result.ContainsExpected == true
                        ? "marker PASS"
                        : "marker FAIL";

            SetStatus(
                result.Ok ? "PROOF" : "ERROR",
                $"HTTP {result.Status} · {proof} · response={result.ResponseLength} chars · {result.ElapsedMs} ms");
        }
        catch (Exception ex)
        {
            ReplayResultTextBox.Text = ex.ToString();
            SetStatus("ERROR", ex.Message);
        }
        finally
        {
            ReplayButton.IsEnabled = true;
        }
    }

    private void SetStatus(string state, string detail)
    {
        OperationStatusText.Text =
            $"Статус: {state} · {detail}";
    }
}
