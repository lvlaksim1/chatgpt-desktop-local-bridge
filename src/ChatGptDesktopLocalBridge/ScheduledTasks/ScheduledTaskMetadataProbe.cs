using System.Collections.Concurrent;
using System.Text;
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
    private CoreWebView2DevToolsProtocolEventReceiver? _finishedReceiver;
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
            $"scheduled-file-transport-probe-{DateTime.UtcNow:yyyyMMdd}.jsonl");
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
            // Tab may already be navigating or closing.
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
                !ScheduledTaskTrafficFilter.TryClassify(url, out var kind))
            {
                return;
            }

            var method = request.TryGetProperty("method", out var methodElement)
                ? methodElement.GetString() ?? "GET"
                : "GET";

            var requestBody =
                request.TryGetProperty("postData", out var postDataElement) &&
                postDataElement.ValueKind == JsonValueKind.String
                    ? postDataElement.GetString()
                    : null;

            _pending[requestId] = new MutableTraffic
            {
                Sequence = Interlocked.Increment(ref _sequence),
                TimestampUtc = DateTimeOffset.UtcNow,
                RequestId = requestId,
                Kind = kind,
                Method = method,
                Url = ScheduledTaskTrafficFilter.SanitizeUrl(url!),
                ReplayUrl = url!,
                RequestBody = requestBody,
                RequestSchema = JsonShape.Describe(requestBody)
            };
        }
        catch
        {
            // Diagnostic capture must never alter normal ChatGPT behavior.
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

            if (IsTextMime(traffic.MimeType))
            {
                try
                {
                    var args = JsonSerializer.Serialize(new { requestId });
                    var raw = await _core.CallDevToolsProtocolMethodAsync(
                        "Network.getResponseBody",
                        args);

                    using var bodyDocument = JsonDocument.Parse(raw);
                    var root = bodyDocument.RootElement;
                    var body =
                        root.TryGetProperty("body", out var bodyElement) &&
                        bodyElement.ValueKind == JsonValueKind.String
                            ? bodyElement.GetString()
                            : null;

                    var isBase64 =
                        root.TryGetProperty(
                            "base64Encoded",
                            out var base64Element) &&
                        base64Element.ValueKind == JsonValueKind.True;

                    if (isBase64 && !string.IsNullOrWhiteSpace(body))
                    {
                        try
                        {
                            body = Encoding.UTF8.GetString(
                                Convert.FromBase64String(body));
                        }
                        catch
                        {
                            body = null;
                        }
                    }

                    traffic.ResponseBody = body;
                    traffic.ResponseSchema = JsonShape.Describe(body);
                }
                catch (Exception ex)
                {
                    traffic.ResponseSchema =
                        $"(response schema unavailable: {ex.Message})";
                }
            }
            else
            {
                traffic.ResponseSchema =
                    $"(body omitted; MIME={traffic.MimeType ?? "unknown"})";
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
            traffic.Kind,
            traffic.Method,
            traffic.Url,
            traffic.RequestSchema,
            traffic.Status,
            traffic.MimeType,
            traffic.ResponseSchema,
            traffic.Error,
            traffic.ReplayUrl,
            traffic.RequestBody,
            traffic.ResponseBody);

        lock (_sync)
        {
            _completed.Add(entry);

            while (_completed.Count > 800)
            {
                _completed.RemoveAt(0);
            }
        }

        try
        {
            var durableMetadata = new
            {
                entry.Sequence,
                entry.TimestampUtc,
                entry.RequestId,
                kind = entry.Kind.ToString(),
                entry.Method,
                entry.Url,
                entry.RequestSchema,
                entry.Status,
                entry.MimeType,
                entry.ResponseSchema,
                entry.Error
            };

            File.AppendAllText(
                LogPath,
                JsonSerializer.Serialize(durableMetadata) +
                Environment.NewLine);
        }
        catch
        {
            // Probe logging must never interfere with normal browser behavior.
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
        public BackendProbeKind Kind { get; init; }
        public required string Method { get; init; }
        public required string Url { get; init; }
        public required string ReplayUrl { get; init; }
        public string? RequestBody { get; init; }
        public string? RequestSchema { get; init; }
        public int? Status { get; set; }
        public string? MimeType { get; set; }
        public string? ResponseBody { get; set; }
        public string? ResponseSchema { get; set; }
        public string? Error { get; set; }
    }
}
