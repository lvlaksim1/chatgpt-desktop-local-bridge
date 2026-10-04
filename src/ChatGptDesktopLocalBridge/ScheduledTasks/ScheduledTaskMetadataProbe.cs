using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed class ScheduledTaskMetadataProbe : IAsyncDisposable
{
    private readonly CoreWebView2 _core;
    private readonly ConcurrentDictionary<string, MutableTraffic> _pending =
        new(StringComparer.Ordinal);
    private readonly List<ScheduledTaskTrafficEntry> _completed = new();
    private readonly object _sync = new();

    private CoreWebView2DevToolsProtocolEventReceiver? _requestReceiver;
    private CoreWebView2DevToolsProtocolEventReceiver? _responseReceiver;
    private CoreWebView2DevToolsProtocolEventReceiver? _failedReceiver;
    private long _sequence;
    private bool _running;

    public ScheduledTaskMetadataProbe(CoreWebView2 core)
    {
        _core = core;

        var logDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "logs");

        Directory.CreateDirectory(logDirectory);
        LogPath = Path.Combine(
            logDirectory,
            $"scheduled-task-probe-{DateTime.UtcNow:yyyyMMdd}.jsonl");
    }

    public string LogPath { get; }

    public bool IsRunning => _running;

    public async Task StartAsync()
    {
        if (_running)
        {
            return;
        }

        _requestReceiver =
            _core.GetDevToolsProtocolEventReceiver("Network.requestWillBeSent");
        _responseReceiver =
            _core.GetDevToolsProtocolEventReceiver("Network.responseReceived");
        _failedReceiver =
            _core.GetDevToolsProtocolEventReceiver("Network.loadingFailed");

        _requestReceiver.DevToolsProtocolEventReceived += OnRequestWillBeSent;
        _responseReceiver.DevToolsProtocolEventReceived += OnResponseReceived;
        _failedReceiver.DevToolsProtocolEventReceived += OnLoadingFailed;

        await _core.CallDevToolsProtocolMethodAsync("Network.enable", "{}");
        _running = true;
    }

    public async Task StopAsync()
    {
        if (!_running)
        {
            return;
        }

        _running = false;

        if (_requestReceiver is not null)
        {
            _requestReceiver.DevToolsProtocolEventReceived -= OnRequestWillBeSent;
        }

        if (_responseReceiver is not null)
        {
            _responseReceiver.DevToolsProtocolEventReceived -= OnResponseReceived;
        }

        if (_failedReceiver is not null)
        {
            _failedReceiver.DevToolsProtocolEventReceived -= OnLoadingFailed;
        }

        try
        {
            await _core.CallDevToolsProtocolMethodAsync("Network.disable", "{}");
        }
        catch
        {
        }
    }

    public IReadOnlyList<ScheduledTaskTrafficEntry> Snapshot()
    {
        lock (_sync)
        {
            return _completed.ToArray();
        }
    }

    public void Clear()
    {
        _pending.Clear();

        lock (_sync)
        {
            _completed.Clear();
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
    }

    private void OnRequestWillBeSent(
        object? sender,
        CoreWebView2DevToolsProtocolEventReceivedEventArgs e)
    {
        try
        {
            using var document = JsonDocument.Parse(e.ParameterObjectAsJson);
            var root = document.RootElement;

            if (!root.TryGetProperty("requestId", out var requestIdElement) ||
                !root.TryGetProperty("request", out var request))
            {
                return;
            }

            var requestId = requestIdElement.GetString();
            var url = request.TryGetProperty("url", out var urlElement)
                ? urlElement.GetString()
                : null;

            if (string.IsNullOrWhiteSpace(requestId) ||
                !ScheduledTaskTrafficFilter.IsCandidate(url))
            {
                return;
            }

            var method = request.TryGetProperty("method", out var methodElement)
                ? methodElement.GetString() ?? "GET"
                : "GET";

            _pending[requestId] = new MutableTraffic
            {
                Sequence = Interlocked.Increment(ref _sequence),
                TimestampUtc = DateTimeOffset.UtcNow,
                RequestId = requestId,
                Method = method,
                Url = ScheduledTaskTrafficFilter.SanitizeUrl(url!)
            };
        }
        catch
        {
            // Diagnostics are fail-closed and never affect the page.
        }
    }

    private void OnResponseReceived(
        object? sender,
        CoreWebView2DevToolsProtocolEventReceivedEventArgs e)
    {
        try
        {
            using var document = JsonDocument.Parse(e.ParameterObjectAsJson);
            var root = document.RootElement;

            if (!root.TryGetProperty("requestId", out var requestIdElement))
            {
                return;
            }

            var requestId = requestIdElement.GetString();
            if (string.IsNullOrWhiteSpace(requestId) ||
                !_pending.TryRemove(requestId, out var traffic) ||
                !root.TryGetProperty("response", out var response))
            {
                return;
            }

            if (response.TryGetProperty("status", out var status) &&
                status.TryGetDouble(out var statusValue))
            {
                traffic.Status = (int)Math.Round(statusValue);
            }

            if (response.TryGetProperty("mimeType", out var mimeType) &&
                mimeType.ValueKind == JsonValueKind.String)
            {
                traffic.MimeType = mimeType.GetString();
            }

            Complete(traffic);
        }
        catch
        {
        }
    }

    private void OnLoadingFailed(
        object? sender,
        CoreWebView2DevToolsProtocolEventReceivedEventArgs e)
    {
        try
        {
            using var document = JsonDocument.Parse(e.ParameterObjectAsJson);
            var root = document.RootElement;

            if (!root.TryGetProperty("requestId", out var requestIdElement))
            {
                return;
            }

            var requestId = requestIdElement.GetString();
            if (string.IsNullOrWhiteSpace(requestId) ||
                !_pending.TryRemove(requestId, out var traffic))
            {
                return;
            }

            traffic.Error =
                root.TryGetProperty("errorText", out var errorElement) &&
                errorElement.ValueKind == JsonValueKind.String
                    ? errorElement.GetString()
                    : "network request failed";

            Complete(traffic);
        }
        catch
        {
        }
    }

    private void Complete(MutableTraffic traffic)
    {
        var entry = new ScheduledTaskTrafficEntry(
            traffic.Sequence,
            traffic.TimestampUtc,
            traffic.RequestId,
            traffic.Method,
            traffic.Url,
            traffic.Status,
            traffic.MimeType,
            traffic.Error);

        lock (_sync)
        {
            _completed.Add(entry);

            while (_completed.Count > 500)
            {
                _completed.RemoveAt(0);
            }
        }

        try
        {
            File.AppendAllText(
                LogPath,
                JsonSerializer.Serialize(entry) + Environment.NewLine);
        }
        catch
        {
        }
    }

    private sealed class MutableTraffic
    {
        public long Sequence { get; init; }
        public DateTimeOffset TimestampUtc { get; init; }
        public required string RequestId { get; init; }
        public required string Method { get; init; }
        public required string Url { get; init; }
        public int? Status { get; set; }
        public string? MimeType { get; set; }
        public string? Error { get; set; }
    }
}
