using System.Text.Json;

namespace ChatGptDesktopLocalBridge;

public sealed class AppSettings
{
    public bool AutoInitializeBridge { get; set; } = true;
    public string ShellTheme { get; set; } = "Dark";
    public string ChatBackground { get; set; } = "";
    public double RightPanelWidth { get; set; } = 360;
    public List<string> TabUrls { get; set; } = new() { "https://chatgpt.com/" };
    public int SelectedTabIndex { get; set; }
    public double WindowWidth { get; set; } = 1440;
    public double WindowHeight { get; set; } = 900;
    public double? WindowLeft { get; set; }
    public double? WindowTop { get; set; }

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
                return new AppSettings();
            }

            var json = File.ReadAllText(SettingsPath);
            var settings = JsonSerializer.Deserialize<AppSettings>(
                json,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

            if (settings is null)
            {
                return new AppSettings();
            }

            settings.RightPanelWidth = Math.Clamp(settings.RightPanelWidth, 260, 760);
            settings.WindowWidth = Math.Max(settings.WindowWidth, 1000);
            settings.WindowHeight = Math.Max(settings.WindowHeight, 650);
            settings.TabUrls = settings.TabUrls
                .Where(static value =>
                    Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
                    uri.Scheme == Uri.UriSchemeHttps &&
                    (uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
                     uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase)))
                .Distinct(StringComparer.Ordinal)
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

            if (settings.ShellTheme is not ("Dark" or "Light" or "System"))
            {
                settings.ShellTheme = "Dark";
            }

            return settings;
        }
        catch
        {
            return new AppSettings();
        }
    }

    public void Save()
    {
        var path = SettingsPath;
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);

        var temp = path + ".tmp";
        var json = JsonSerializer.Serialize(
            this,
            new JsonSerializerOptions { WriteIndented = true });

        File.WriteAllText(temp, json);
        File.Move(temp, path, true);
    }
}
