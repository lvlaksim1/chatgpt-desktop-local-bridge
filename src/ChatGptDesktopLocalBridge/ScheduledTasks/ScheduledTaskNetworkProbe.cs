using System.Collections.Concurrent;
using System.Text;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed class ScheduledTaskNetworkProbe : IAsyncDisposable
{
    private readonly CoreWebView2 _core;
    private readonly ConcurrentDictionary<string, MutableTraffic> _pending =
        new(StringComparer.Ordinal);
    private readonly List<ScheduledTaskTrafficEntry> _completed = new();
    private readonly object _completedSync = new();

    private CoreWebView2DevToolsProtocolEventReceiver? _requestReceiver;
    private CoreWebView2DevToolsProtocolEventReceiver? _responseReceiver;
    private CoreWebView2DevToolsProtocolEventReceiver? _finishedReceiver;
    private CoreWebView2DevToolsProtocolEventReceiver? _failedReceiver;
    private long _sequence;
    private bool _running;

    public ScheduledTaskNetworkProbe(CoreWebView2 core)
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
        _finishedReceiver =
            _core.GetDevToolsProtocolEventReceiver("Network.loadingFinished");
        _failedReceiver =
            _core.GetDevToolsProtocolEventReceiver("Network.loadingFailed");

        _requestReceiver.DevToolsProtocolEventReceived += OnRequestWillBeSent;
        _responseReceiver.DevToolsProtocolEventReceived += OnResponseReceived;
        _finishedReceiver.DevToolsProtocolEventReceived += OnLoadingFinished;
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

        if (_finishedReceiver is not null)
        {
            _finishedReceiver.DevToolsProtocolEventReceived -= OnLoadingFinished;
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
            // The tab may already be navigating or shutting down.
        }
    }

    public IReadOnlyList<ScheduledTaskTrafficEntry> Snapshot()
    {
        lock (_completedSync)
        {
            return _completed.ToArray();
        }
    }

    public void Clear()
    {
        _pending.Clear();

        lock (_completedSync)
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
                !ScheduledTaskProbeSanitizer.IsCandidateTaskUrl(url))
            {
                return;
            }

            var method = request.TryGetProperty("method", out var methodElement)
                ? methodElement.GetString() ?? "GET"
                : "GET";

            var body = request.TryGetProperty("postData", out var postDataElement) &&
                       postDataElement.ValueKind == JsonValueKind.String
                ? postDataElement.GetString()
                : null;

            _pending[requestId] = new MutableTraffic
            {
                Sequence = Interlocked.Increment(ref _sequence),
                TimestampUtc = DateTimeOffset.UtcNow,
                RequestId = requestId,
                Method = method,
                Url = ScheduledTaskProbeSanitizer.SanitizeUrl(url!),
                ReplayUrl = url!,
                RequestBody = ScheduledTaskProbeSanitizer.SanitizeBody(body)
            };
        }
        catch
        {
            // Diagnostic capture must never affect normal page behavior.
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
                !_pending.TryGetValue(requestId, out var traffic) ||
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
        }
        catch
        {
        }
    }

    private async void OnLoadingFinished(
        object? sender,
        CoreWebView2DevToolsProtocolEventReceivedEventArgs e)
    {
        string? requestId = null;

        try
        {
            using var document = JsonDocument.Parse(e.ParameterObjectAsJson);
            if (!document.RootElement.TryGetProperty(
                    "requestId",
                    out var requestIdElement))
            {
                return;
            }

            requestId = requestIdElement.GetString();
            if (string.IsNullOrWhiteSpace(requestId) ||
                !_pending.TryRemove(requestId, out var traffic))
            {
                return;
            }

            try
            {
                var parameters = JsonSerializer.Serialize(
                    new { requestId });

                var raw = await _core.CallDevToolsProtocolMethodAsync(
                    "Network.getResponseBody",
                    parameters);

                using var responseDocument = JsonDocument.Parse(raw);
                var responseRoot = responseDocument.RootElement;

                if (responseRoot.TryGetProperty("body", out var bodyElement) &&
                    bodyElement.ValueKind == JsonValueKind.String)
                {
                    var body = bodyElement.GetString();
                    var base64 = responseRoot.TryGetProperty(
                                     "base64Encoded",
                                     out var base64Element) &&
                                 base64Element.ValueKind == JsonValueKind.True;

                    if (base64 &&
                        !string.IsNullOrWhiteSpace(body) &&
                        IsTextMime(traffic.MimeType))
                    {
                        try
                        {
                            body = Encoding.UTF8.GetString(
                                Convert.FromBase64String(body));
                        }
                        catch
                        {
                            body = "<encoded response body omitted>";
                        }
                    }
                    else if (base64)
                    {
                        body = "<encoded response body omitted>";
                    }

                    traffic.ResponseBody =
                        ScheduledTaskProbeSanitizer.SanitizeBody(body);
                }
            }
            catch (Exception ex)
            {
                traffic.Error = "response-body-unavailable: " + ex.Message;
            }

            Complete(traffic);
        }
        catch (Exception ex)
        {
            if (!string.IsNullOrWhiteSpace(requestId) &&
                _pending.TryRemove(requestId, out var traffic))
            {
                traffic.Error = ex.Message;
                Complete(traffic);
            }
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
            traffic.ReplayUrl,
            traffic.RequestBody,
            traffic.Status,
            traffic.MimeType,
            traffic.ResponseBody,
            traffic.Error);

        lock (_completedSync)
        {
            _completed.Add(entry);

            while (_completed.Count > 500)
            {
                _completed.RemoveAt(0);
            }
        }

        try
        {
            var json = JsonSerializer.Serialize(entry);
            File.AppendAllText(LogPath, json + Environment.NewLine);
        }
        catch
        {
            // Diagnostics must not interfere with the browser.
        }
    }

    private static bool IsTextMime(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        return value.Contains("json", StringComparison.OrdinalIgnoreCase) ||
               value.Contains("text", StringComparison.OrdinalIgnoreCase) ||
               value.Contains("javascript", StringComparison.OrdinalIgnoreCase);
    }

    private sealed class MutableTraffic
    {
        public long Sequence { get; init; }
        public DateTimeOffset TimestampUtc { get; init; }
        public required string RequestId { get; init; }
        public required string Method { get; init; }
        public required string Url { get; init; }
        public required string ReplayUrl { get; init; }
        public string? RequestBody { get; init; }
        public int? Status { get; set; }
        public string? MimeType { get; set; }
        public string? ResponseBody { get; set; }
        public string? Error { get; set; }
    }
}