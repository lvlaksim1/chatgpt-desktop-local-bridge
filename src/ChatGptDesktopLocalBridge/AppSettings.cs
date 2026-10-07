using System.Text.Json;

namespace ChatGptDesktopLocalBridge;

public sealed class AppSettings
{
    public bool AutoInitializeBridge { get; set; } = true;
    public string ThemeColor { get; set; } = "#202124";
    public double RightPanelWidth { get; set; } = 360;
    public List<string> TabUrls { get; set; } = new() { "https://chatgpt.com/" };
    public int SelectedTabIndex { get; set; }
    public double WindowWidth { get; set; } = 1440;
    public double WindowHeight { get; set; } = 900;
    public double? WindowLeft { get; set; }
    public double? WindowTop { get; set; }
    public int UpdateCheckIntervalMinutes { get; set; } = 30;
    public string? LocalIntentWorkerAutomationId { get; set; }
    public bool LocalIntentWorkerProvisioningUncertain { get; set; }

    // Legacy 0.2.x fields retained only for migration.
    public string? ShellTheme { get; set; }
    public string? ChatBackground { get; set; }

    public static string SettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ChatGptDesktopLocalBridge",
        "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath))
            {
                return Normalize(new AppSettings());
            }

            var json = File.ReadAllText(SettingsPath);
            var settings = JsonSerializer.Deserialize<AppSettings>(
                json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? new AppSettings();

            return Normalize(settings);
        }
        catch
        {
            return Normalize(new AppSettings());
        }
    }

    private static AppSettings Normalize(AppSettings settings)
    {
        if (!ThemePalette.IsValidHex(settings.ThemeColor))
        {
            if (ThemePalette.IsValidHex(settings.ChatBackground))
            {
                settings.ThemeColor = settings.ChatBackground!;
            }
            else
            {
                settings.ThemeColor = string.Equals(
                    settings.ShellTheme,
                    "Light",
                    StringComparison.OrdinalIgnoreCase)
                    ? "#F2F3F5"
                    : "#202124";
            }
        }

        settings.RightPanelWidth = Math.Clamp(settings.RightPanelWidth, 260, 760);
        settings.WindowWidth = Math.Max(settings.WindowWidth, 1000);
        settings.WindowHeight = Math.Max(settings.WindowHeight, 650);
        settings.UpdateCheckIntervalMinutes =
            Math.Clamp(settings.UpdateCheckIntervalMinutes, 5, 1440);

        settings.TabUrls = settings.TabUrls
            .Where(IsChatUrl)
            .Select(CanonicalizeUrl)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(12)
            .ToList();

        if (settings.TabUrls.Count == 0)
        {
            settings.TabUrls.Add("https://chatgpt.com/");
        }

        settings.SelectedTabIndex = Math.Clamp(
            settings.SelectedTabIndex,
            0,
            settings.TabUrls.Count - 1);

        return settings;
    }

    public void Save()
    {
        var path = SettingsPath;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);

        var temp = path + ".tmp";
        var json = JsonSerializer.Serialize(
            this,
            new JsonSerializerOptions { WriteIndented = true });

        File.WriteAllText(temp, json);
        File.Move(temp, path, true);
    }

    public static bool IsChatUrl(string? value)
        => Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
           uri.Scheme == Uri.UriSchemeHttps &&
           (uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
            uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase));

    public static string CanonicalizeUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
        {
            return "https://chatgpt.com/";
        }

        var builder = new UriBuilder(uri) { Fragment = string.Empty };
        var result = builder.Uri.AbsoluteUri;

        if (builder.Uri.AbsolutePath == "/" &&
            string.IsNullOrEmpty(builder.Uri.Query))
        {
            return "https://chatgpt.com/";
        }

        return result.TrimEnd('/');
    }
}
