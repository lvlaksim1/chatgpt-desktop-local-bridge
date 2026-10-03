using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public static class ScheduledTaskProbeSanitizer
{
    private const int MaxBodyChars = 200_000;

    private static readonly string[] SensitiveNameFragments =
    [
        "token",
        "cookie",
        "auth",
        "secret",
        "password",
        "session",
        "csrf"
    ];

    public static bool IsCandidateTaskUrl(string? value)
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

        var text = uri.AbsolutePath.ToLowerInvariant();
        return text.Contains("task", StringComparison.Ordinal) ||
               text.Contains("schedul", StringComparison.Ordinal) ||
               text.Contains("automat", StringComparison.Ordinal) ||
               text.Contains("remind", StringComparison.Ordinal) ||
               text.Contains("jawbone", StringComparison.Ordinal);
    }

    public static string SanitizeUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return value;
        }

        var builder = new UriBuilder(uri) { Fragment = string.Empty };
        if (string.IsNullOrWhiteSpace(builder.Query))
        {
            return builder.Uri.AbsoluteUri;
        }

        var names = builder.Query
            .TrimStart('?')
            .Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => Uri.UnescapeDataString(part.Split('=', 2)[0]))
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Select(name => $"{Uri.EscapeDataString(name)}=%3Credacted%3E");

        builder.Query = string.Join("&", names);
        return builder.Uri.AbsoluteUri;
    }

    public static string? SanitizeBody(string? body)
    {
        if (string.IsNullOrWhiteSpace(body))
        {
            return body;
        }

        var text = body.Length > MaxBodyChars
            ? body[..MaxBodyChars]
            : body;

        try
        {
            var node = JsonNode.Parse(text);
            Redact(node);
            return node?.ToJsonString(
                new JsonSerializerOptions { WriteIndented = true });
        }
        catch
        {
            return text;
        }
    }

    public static string? CreateBodyTemplate(
        string? body,
        string? sourceTaskId)
    {
        var sanitized = SanitizeBody(body);
        if (string.IsNullOrWhiteSpace(sanitized))
        {
            return sanitized;
        }

        try
        {
            var node = JsonNode.Parse(sanitized);
            Template(node, sourceTaskId);
            return node?.ToJsonString(
                new JsonSerializerOptions { WriteIndented = true });
        }
        catch
        {
            return sanitized;
        }
    }

    public static string CreateUrlTemplate(
        string url,
        string? sourceTaskId)
    {
        if (string.IsNullOrWhiteSpace(sourceTaskId))
        {
            return url;
        }

        return url.Replace(
            sourceTaskId,
            "{{TASK_ID}}",
            StringComparison.Ordinal);
    }

    public static JsonNode? BuildBody(
        string? template,
        string taskId,
        string? prompt,
        bool? enabled,
        DateTimeOffset? startAt)
    {
        if (string.IsNullOrWhiteSpace(template))
        {
            return null;
        }

        var node = JsonNode.Parse(template)
            ?? throw new InvalidOperationException("Saved body template is empty.");

        Replace(node, taskId, prompt, enabled, startAt);
        return node;
    }

    public static string ExpandUrl(string template, string taskId)
        => template.Replace(
            "{{TASK_ID}}",
            Uri.EscapeDataString(taskId),
            StringComparison.Ordinal);

    private static void Redact(JsonNode? node)
    {
        if (node is JsonObject obj)
        {
            foreach (var key in obj.Select(pair => pair.Key).ToArray())
            {
                var normalized = key.Replace("-", "_").ToLowerInvariant();
                if (SensitiveNameFragments.Any(fragment =>
                        normalized.Contains(fragment, StringComparison.Ordinal)))
                {
                    obj[key] = "<redacted>";
                }
                else
                {
                    Redact(obj[key]);
                }
            }

            return;
        }

        if (node is JsonArray array)
        {
            foreach (var child in array)
            {
                Redact(child);
            }
        }
    }

    private static void Template(JsonNode? node, string? sourceTaskId)
    {
        if (node is JsonObject obj)
        {
            foreach (var key in obj.Select(pair => pair.Key).ToArray())
            {
                var normalized = key.Replace("-", "_").ToLowerInvariant();

                if (normalized is "prompt" or "instructions" or "message")
                {
                    obj[key] = "{{PROMPT}}";
                    continue;
                }

                if (normalized is "is_enabled" or "enabled")
                {
                    obj[key] = "{{ENABLED}}";
                    continue;
                }

                if ((normalized.Contains("schedule", StringComparison.Ordinal) ||
                     normalized.Contains("dtstart", StringComparison.Ordinal) ||
                     normalized.Contains("start_date", StringComparison.Ordinal) ||
                     normalized.Contains("start_time", StringComparison.Ordinal)) &&
                    obj[key] is JsonValue)
                {
                    obj[key] = "{{SCHEDULE}}";
                    continue;
                }

                if (!string.IsNullOrWhiteSpace(sourceTaskId) &&
                    obj[key] is JsonValue value &&
                    value.TryGetValue<string>(out var text))
                {
                    obj[key] = text.Replace(
                        sourceTaskId,
                        "{{TASK_ID}}",
                        StringComparison.Ordinal);
                }
                else
                {
                    Template(obj[key], sourceTaskId);
                }
            }

            return;
        }

        if (node is JsonArray array)
        {
            foreach (var child in array)
            {
                Template(child, sourceTaskId);
            }
        }
    }

    private static void Replace(
        JsonNode? node,
        string taskId,
        string? prompt,
        bool? enabled,
        DateTimeOffset? startAt)
    {
        if (node is JsonObject obj)
        {
            foreach (var key in obj.Select(pair => pair.Key).ToArray())
            {
                if (obj[key] is JsonValue value &&
                    value.TryGetValue<string>(out var text))
                {
                    if (text == "{{PROMPT}}")
                    {
                        obj[key] = prompt ?? string.Empty;
                    }
                    else if (text == "{{ENABLED}}")
                    {
                        obj[key] = enabled ?? false;
                    }
                    else if (text == "{{SCHEDULE}}")
                    {
                        obj[key] = startAt.HasValue
                            ? startAt.Value.ToString("yyyy-MM-ddTHH:mm:sszzz")
                            : text;
                    }
                    else
                    {
                        obj[key] = text.Replace(
                            "{{TASK_ID}}",
                            taskId,
                            StringComparison.Ordinal);
                    }

                    continue;
                }

                Replace(obj[key], taskId, prompt, enabled, startAt);
            }

            return;
        }

        if (node is JsonArray array)
        {
            foreach (var child in array)
            {
                Replace(child, taskId, prompt, enabled, startAt);
            }
        }
    }
}
