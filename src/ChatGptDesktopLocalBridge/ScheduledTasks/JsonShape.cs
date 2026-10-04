using System.Text;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public static class JsonShape
{
    private const int MaxEntries = 256;
    private const int MaxDepth = 8;

    public static string Describe(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return "(empty)";
        }

        try
        {
            using var document = JsonDocument.Parse(value);
            var lines = new List<string>();
            Walk(document.RootElement, "$", 0, lines);

            if (lines.Count == 0)
            {
                return "(json-empty)";
            }

            return string.Join(Environment.NewLine, lines);
        }
        catch
        {
            return $"(non-json text; {value.Length} chars)";
        }
    }

    private static void Walk(
        JsonElement element,
        string path,
        int depth,
        ICollection<string> lines)
    {
        if (lines.Count >= MaxEntries)
        {
            return;
        }

        if (depth >= MaxDepth)
        {
            lines.Add($"{path}: …");
            return;
        }

        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                lines.Add($"{path}: object");
                foreach (var property in element.EnumerateObject())
                {
                    Walk(
                        property.Value,
                        path + "." + property.Name,
                        depth + 1,
                        lines);

                    if (lines.Count >= MaxEntries)
                    {
                        break;
                    }
                }
                break;

            case JsonValueKind.Array:
                lines.Add($"{path}: array");
                var first = element.EnumerateArray().FirstOrDefault();
                if (first.ValueKind != JsonValueKind.Undefined)
                {
                    Walk(first, path + "[]", depth + 1, lines);
                }
                break;

            case JsonValueKind.String:
                lines.Add($"{path}: string");
                break;

            case JsonValueKind.Number:
                lines.Add($"{path}: number");
                break;

            case JsonValueKind.True:
            case JsonValueKind.False:
                lines.Add($"{path}: boolean");
                break;

            case JsonValueKind.Null:
                lines.Add($"{path}: null");
                break;

            default:
                lines.Add($"{path}: {element.ValueKind.ToString().ToLowerInvariant()}");
                break;
        }
    }
}
