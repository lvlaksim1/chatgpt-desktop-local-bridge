using System.Text;
using System.Text.Json;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

internal sealed class LocalIntentServiceStateStore
{
    private readonly string _path;
    private readonly object _sync = new();

    public LocalIntentServiceStateStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(
                Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge",
            "local-intent-service.json");
    }

    public string? LoadAutomationId()
    {
        lock (_sync)
        {
            try
            {
                if (!File.Exists(_path))
                {
                    return null;
                }

                using var document = JsonDocument.Parse(
                    File.ReadAllText(_path, Encoding.UTF8));

                if (!document.RootElement.TryGetProperty(
                        "automation_id",
                        out var idElement) ||
                    idElement.ValueKind != JsonValueKind.String)
                {
                    return null;
                }

                var value = idElement.GetString()?.Trim();
                return string.IsNullOrWhiteSpace(value) ? null : value;
            }
            catch
            {
                return null;
            }
        }
    }

    public void SaveAutomationId(string automationId)
    {
        if (string.IsNullOrWhiteSpace(automationId))
        {
            return;
        }

        lock (_sync)
        {
            var directory = Path.GetDirectoryName(_path);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            var json = JsonSerializer.Serialize(
                new
                {
                    schema = "local-bridge-service-task-v1",
                    automation_id = automationId.Trim(),
                    updated_at_utc =
                        DateTimeOffset.UtcNow.ToString("O")
                },
                new JsonSerializerOptions
                {
                    WriteIndented = true
                });

            var temporary = _path + ".tmp";
            File.WriteAllText(
                temporary,
                json + Environment.NewLine,
                new UTF8Encoding(false));
            File.Move(temporary, _path, true);
        }
    }
}
