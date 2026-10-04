namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record ScheduledTaskTrafficEntry(
    long Sequence,
    DateTimeOffset TimestampUtc,
    string RequestId,
    string Method,
    string Url,
    int? Status,
    string? MimeType,
    string? Error)
{
    public string Display =>
        $"{TimestampUtc.ToLocalTime():HH:mm:ss.fff}  {Method,-6}  {(Status?.ToString() ?? "..."),3}  {Url}";
}

public static class ScheduledTaskTrafficFilter
{
    public static bool IsCandidate(string? value)
    {
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
        return path.Contains("task", StringComparison.Ordinal) ||
               path.Contains("schedul", StringComparison.Ordinal) ||
               path.Contains("automat", StringComparison.Ordinal) ||
               path.Contains("remind", StringComparison.Ordinal) ||
               path.Contains("jawbone", StringComparison.Ordinal);
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
}
