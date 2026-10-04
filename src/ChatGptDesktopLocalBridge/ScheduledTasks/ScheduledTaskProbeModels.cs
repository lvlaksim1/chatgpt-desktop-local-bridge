using System.Text.Json;
using System.Text.Json.Serialization;

namespace ChatGptDesktopLocalBridge.ScheduledTasks;

public sealed record ScheduledTaskTrafficEntry(
    long Sequence,
    DateTimeOffset TimestampUtc,
    string RequestId,
    string Method,
    string Url,
    [property: JsonIgnore] string ReplayUrl,
    string? RequestBody,
    int? Status,
    string? MimeType,
    string? ResponseBody,
    string? Error)
{
    public string Display =>
        $"{TimestampUtc.ToLocalTime():HH:mm:ss.fff}  {Method,-6}  {(Status?.ToString() ?? "..."),3}  {Url}";
}

public sealed record ScheduledTaskRequestTemplate(
    string Name,
    string Method,
    string UrlTemplate,
    string? BodyTemplate,
    string? SourceTaskId,
    DateTimeOffset LearnedUtc);

public sealed class ScheduledTaskProbeProfile
{
    public string Schema { get; set; } = "chatgpt-desktop-scheduled-task-probe-v1";
    public ScheduledTaskRequestTemplate? List { get; set; }
    public ScheduledTaskRequestTemplate? Get { get; set; }
    public ScheduledTaskRequestTemplate? Update { get; set; }
    public ScheduledTaskRequestTemplate? Arm { get; set; }

    public static string ProfilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChatGptDesktopLocalBridge",
        "state",
        "scheduled-task-probe-profile.json");

    public static ScheduledTaskProbeProfile Load()
    {
        try
        {
            if (!File.Exists(ProfilePath))
            {
                return new ScheduledTaskProbeProfile();
            }

            var value = JsonSerializer.Deserialize<ScheduledTaskProbeProfile>(
                File.ReadAllText(ProfilePath),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

            return value is not null &&
                   value.Schema == "chatgpt-desktop-scheduled-task-probe-v1"
                ? value
                : new ScheduledTaskProbeProfile();
        }
        catch
        {
            return new ScheduledTaskProbeProfile();
        }
    }

    public void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(ProfilePath)!);
        var temp = ProfilePath + "." + Guid.NewGuid().ToString("N") + ".tmp";

        try
        {
            File.WriteAllText(
                temp,
                JsonSerializer.Serialize(
                    this,
                    new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, ProfilePath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temp))
            {
                File.Delete(temp);
            }
        }
    }
}