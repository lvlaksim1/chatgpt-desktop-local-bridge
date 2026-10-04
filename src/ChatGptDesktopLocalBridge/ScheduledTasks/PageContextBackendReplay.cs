using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record BackendReplayResult(
    PrivateTransportOutcome Outcome,
    bool Ok,
    int Status,
    string Url,
    string ResponseSchema,
    int ResponseLength,
    string ResponseSha256,
    bool? ContainsExpected,
    long ElapsedMs,
    string? Error,
    bool RequiresReadBack);

public sealed class PageContextBackendReplay
{
    private readonly ChatGptPrivateTransport _transport;

    public PageContextBackendReplay(WebView2 browser)
    {
        _transport = new ChatGptPrivateTransport(browser);
    }

    public async Task<BackendReplayResult> ExecuteAsync(
        ScheduledTaskTrafficEntry entry,
        string? requestBodyOverride,
        string? expectedText)
    {
        if (!ScheduledTaskTrafficFilter.IsAllowedReplayUrl(entry.ReplayUrl) ||
            !Uri.TryCreate(entry.ReplayUrl, UriKind.Absolute, out var uri))
        {
            throw new InvalidOperationException(
                "Captured endpoint is outside the allowed ChatGPT origin.");
        }

        var method = entry.Method.Trim().ToUpperInvariant();
        var body = requestBodyOverride ?? entry.RequestBody;
        var mutation = method is "POST" or "PUT" or "PATCH" or "DELETE";

        PrivateTransportResult result;

        if (method is "GET" or "HEAD")
        {
            result = await _transport.GetAsync(uri.PathAndQuery);
        }
        else
        {
            result = await _transport.SendMutationAsync(
                method,
                uri.PathAndQuery,
                string.IsNullOrWhiteSpace(body)
                    ? null
                    : body);
        }

        bool? containsExpected = null;
        if (!string.IsNullOrWhiteSpace(expectedText))
        {
            containsExpected = result.ResponseBody.Contains(
                expectedText,
                StringComparison.Ordinal);
        }

        var requiresReadBack =
            mutation &&
            result.Outcome is
                PrivateTransportOutcome.UnknownOutcome or
                PrivateTransportOutcome.ContextInvalidated;

        return new BackendReplayResult(
            result.Outcome,
            result.Ok,
            result.Status,
            result.Endpoint,
            result.ResponseSchema,
            result.ResponseLength,
            result.ResponseSha256,
            containsExpected,
            result.ElapsedMs,
            result.Error,
            requiresReadBack);
    }
}
