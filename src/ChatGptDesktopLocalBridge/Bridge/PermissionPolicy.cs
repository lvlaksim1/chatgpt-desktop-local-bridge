using System.Text.Json;
using System.Text.Json.Serialization;

namespace ChatGptDesktopLocalBridge.Bridge;

public enum PermissionDecision
{
    Auto,
    Ask,
    Deny
}

public sealed record BridgePermissionPrompt(
    string Tool,
    string Capability,
    string Summary);

public sealed class PermissionPolicy
{
    public string Profile { get; set; } = "safe-default";
    public Dictionary<string, string> Capabilities { get; set; } =
        new(StringComparer.OrdinalIgnoreCase);

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

        var defaultPath = Path.Combine(
            AppContext.BaseDirectory,
            "Config",
            "permissions.default.json");

        if (!File.Exists(userPath))
        {
            File.Copy(defaultPath, userPath);
        }

        var options = new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            WriteIndented = true
        };

        var json = File.ReadAllText(userPath);
        var policy = JsonSerializer.Deserialize<PermissionPolicy>(json, options)
                     ?? throw new InvalidOperationException("permissions.json is invalid.");

        if (File.Exists(defaultPath))
        {
            var defaults = JsonSerializer.Deserialize<PermissionPolicy>(
                File.ReadAllText(defaultPath),
                options);

            var changed = false;
            if (defaults is not null)
            {
                foreach (var pair in defaults.Capabilities)
                {
                    if (!policy.Capabilities.ContainsKey(pair.Key))
                    {
                        policy.Capabilities[pair.Key] = pair.Value;
                        changed = true;
                    }
                }
            }

            if (changed)
            {
                File.WriteAllText(userPath, JsonSerializer.Serialize(policy, options));
            }
        }

        policy.SourcePath = userPath;
        return policy;
    }
}