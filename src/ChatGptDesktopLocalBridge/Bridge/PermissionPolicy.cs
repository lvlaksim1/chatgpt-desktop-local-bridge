using System.Text.Json;
using System.Text.Json.Serialization;

namespace ChatGptDesktopLocalBridge.Bridge;

public enum PermissionDecision
{
    Auto,
    Ask,
    Deny
}

public sealed class PermissionPolicy
{
    public string Profile { get; set; } = "safe-default";
    public Dictionary<string, string> Capabilities { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    [JsonIgnore]
    public string SourcePath { get; private set; } = string.Empty;

    public PermissionDecision GetDecision(string capability)
    {
        if (!Capabilities.TryGetValue(capability, out var raw))
        {
            return PermissionDecision.Deny;
        }

        return raw.Trim().ToUpperInvariant() switch
        {
            "AUTO" => PermissionDecision.Auto,
            "ASK" => PermissionDecision.Ask,
            _ => PermissionDecision.Deny
        };
    }

    public static string GetUserPolicyPath()
    {
        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "ChatGptDesktopLocalBridge");
        return Path.Combine(directory, "permissions.json");
    }

    public static PermissionPolicy LoadOrCreate()
    {
        var userPath = GetUserPolicyPath();
        var directory = Path.GetDirectoryName(userPath)!;
        Directory.CreateDirectory(directory);

        if (!File.Exists(userPath))
        {
            var defaultPath = Path.Combine(
                AppContext.BaseDirectory,
                "Config",
                "permissions.default.json");

            File.Copy(defaultPath, userPath);
        }

        var json = File.ReadAllText(userPath);
        var policy = JsonSerializer.Deserialize<PermissionPolicy>(
                         json,
                         new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                     ?? throw new InvalidOperationException("permissions.json is invalid.");

        policy.SourcePath = userPath;
        return policy;
    }
}
