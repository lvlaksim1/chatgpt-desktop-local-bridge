using System.Text.Json.Serialization;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public enum BackendProbeKind
{
    ScheduledTasks,
    Library
}

public sealed record ScheduledTaskTrafficEntry(
    long Sequence,
    DateTimeOffset TimestampUtc,
    string RequestId,
    BackendProbeKind Kind,
    string Method,
    string Url,
    string? RequestSchema,
    int? Status,
    string? MimeType,
    string? ResponseSchema,
    string? Error,
    [property: JsonIgnore] string ReplayUrl,
    [property: JsonIgnore] string? RequestBody,
    [property: JsonIgnore] string? ResponseBody)
{
    public string Display =>
        $"{TimestampUtc.ToLocalTime():HH:mm:ss.fff}  {Kind,-14}  {Method,-6}  {(Status?.ToString() ?? "..."),3}  {Url}";
}

public static class ScheduledTaskTrafficFilter
{
    private static readonly string[] TaskFragments =
    [
        "task",
        "schedul",
        "automat",
        "remind",
        "jawbone"
    ];

    private static readonly string[] LibraryFragments =
    [
        "library",
        "file",
        "files",
        "upload",
        "uploads",
        "asset",
        "assets",
        "document",
        "documents"
    ];

    public static bool TryClassify(
        string? value,
        out BackendProbeKind kind)
    {
        kind = default;

        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return false;
        }

        if (uri.Scheme != Uri.UriSchemeHttps ||
            !(uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
              uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase)))
        {
            return false;
        }

        var path = uri.AbsolutePath.ToLowerInvariant();

        if (TaskFragments.Any(fragment =>
                path.Contains(fragment, StringComparison.Ordinal)))
        {
            kind = BackendProbeKind.ScheduledTasks;
            return true;
        }

        if (LibraryFragments.Any(fragment =>
                path.Contains(fragment, StringComparison.Ordinal)))
        {
            kind = BackendProbeKind.Library;
            return true;
        }

        return false;
    }

    public static string SanitizeUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return value;
        }

        return new UriBuilder(uri)
        {
            Query = string.Empty,
            Fragment = string.Empty
        }.Uri.AbsoluteUri;
    }

    public static bool IsAllowedReplayUrl(string? value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return false;
        }

        return uri.Scheme == Uri.UriSchemeHttps &&
               (uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
                uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase));
    }
}
