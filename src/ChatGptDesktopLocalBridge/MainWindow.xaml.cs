using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;
using Microsoft.Win32;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private readonly string _appDataRoot;
    private readonly AppSettings _settings;
    private readonly List<ChatTab> _tabs = new();

    private CoreWebView2Environment? _webEnvironment;
    private string _adapterScript = string.Empty;
    private UpdateCandidate? _availableUpdate;
    private bool _applicationReady;

    private sealed class ChatTab
    {
        public required WebView2 Browser { get; init; }
        public required TabItem Item { get; init; }
        public required TextBlock HeaderText { get; init; }
        public required string LastUrl { get; set; }

        public BridgeHost? BridgeHost { get; set; }
        public TaskCompletionSource<bool>? ReadyCompletion { get; set; }
        public bool BridgeReady { get; set; }
        public bool NavigationReady { get; set; }
        public string? LastBootstrappedUrl { get; set; }
    }

    public MainWindow()
    {
        _settings = AppSettings.Load();

        InitializeComponent();

        _appDataRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge");

        VersionText.Text = LoadDisplayVersion();
        BridgePanelColumn.Width = new GridLength(_settings.RightPanelWidth);

        Width = _settings.WindowWidth;
        Height = _settings.WindowHeight;

        if (_settings.WindowLeft.HasValue)
        {
            Left = _settings.WindowLeft.Value;
        }

        if (_settings.WindowTop.HasValue)
        {
            Top = _settings.WindowTop.Value;
        }

        ApplyShellTheme();

        SourceInitialized += MainWindow_OnSourceInitialized;
        StateChanged += (_, _) => UpdateMaximizeButton();
        Closing += MainWindow_OnClosing;
        Loaded += async (_, _) => await InitializeApplicationAsync();
    }

    private ChatTab? ActiveTab =>
        ChatTabs.SelectedItem is TabItem selected
            ? _tabs.FirstOrDefault(tab => ReferenceEquals(tab.Item, selected))
            : null;

    private static string LoadDisplayVersion()
    {
        var identity = UpdateService.LoadInstalledIdentity();
        if (!string.IsNullOrWhiteSpace(identity?.AppVersion))
        {
            return $"v{identity.AppVersion}";
        }

        var assemblyVersion = typeof(MainWindow).Assembly.GetName().Version?.ToString();
        return $"v{assemblyVersion ?? "dev"}";
    }

    private async Task InitializeApplicationAsync()
    {
        try
        {
            Directory.CreateDirectory(_appDataRoot);

            var userDataFolder = Path.Combine(_appDataRoot, "WebView2");
            _webEnvironment = await CoreWebView2Environment.CreateAsync(
                userDataFolder: userDataFolder);

            var adapterPath = Path.Combine(
                AppContext.BaseDirectory,
                "Web",
                "bridge-adapter.js");

            _adapterScript = await File.ReadAllTextAsync(adapterPath);

            foreach (var url in _settings.TabUrls.Take(12))
            {
                await AddChatTabAsync(url, select: false);
            }

            if (_tabs.Count == 0)
            {
                await AddChatTabAsync("https://chatgpt.com/", select: false);
            }

            ChatTabs.SelectedIndex = Math.Clamp(
                _settings.SelectedTabIndex,
                0,
                ChatTabs.Items.Count - 1);

            _applicationReady = true;
            SetStatus("ChatGPT загружается…");

            _ = CheckForUpdatesAsync();
        }
        catch (Exception ex)
        {
            SetStatus($"Ошибка запуска: {ex.Message}");
        }
    }

    private void MainWindow_OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        SaveRuntimeSettings();

        foreach (var tab in _tabs)
        {
            tab.Browser.Dispose();
        }
    }

    private void SaveRuntimeSettings()
    {
        if (BridgePanelColumn.ActualWidth > 0)
        {
            _settings.RightPanelWidth = Math.Clamp(
                BridgePanelColumn.ActualWidth,
                260,
                760);
        }

        _settings.SelectedTabIndex = Math.Max(ChatTabs.SelectedIndex, 0);
        _settings.TabUrls = _tabs
            .Select(tab => tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl)
            .Where(static url => !string.IsNullOrWhiteSpace(url))
            .Distinct(StringComparer.Ordinal)
            .Take(12)
            .ToList();

        if (_settings.TabUrls.Count == 0)
        {
            _settings.TabUrls.Add("https://chatgpt.com/");
        }

        var bounds = WindowState == WindowState.Normal
            ? new Rect(Left, Top, Width, Height)
            : RestoreBounds;

        _settings.WindowLeft = bounds.Left;
        _settings.WindowTop = bounds.Top;
        _settings.WindowWidth = Math.Max(bounds.Width, 1000);
        _settings.WindowHeight = Math.Max(bounds.Height, 650);

        _settings.Save();
    }

    private void SetStatus(string message)
    {
        StatusText.Text = message;
    }

    private void ReloadButton_OnClick(object sender, RoutedEventArgs e)
    {
        ActiveTab?.Browser.Reload();
    }

    private async void NewChatButton_OnClick(object sender, RoutedEventArgs e)
    {
        await AddChatTabAsync("https://chatgpt.com/", select: true);
    }

    private async void SettingsButton_OnClick(object sender, RoutedEventArgs e)
    {
        var window = new SettingsWindow(_settings)
        {
            Owner = this
        };

        if (window.ShowDialog() != true)
        {
            return;
        }

        _settings.ShellTheme = window.SelectedShellTheme;
        _settings.ChatBackground = window.SelectedChatBackground;
        _settings.AutoInitializeBridge = window.SelectedAutoInitializeBridge;
        _settings.Save();

        ApplyShellTheme();
        await ApplyChatBackgroundToAllTabsAsync();

        if (_settings.AutoInitializeBridge && ActiveTab is { } tab)
        {
            _ = EnsureBridgeForTabAsync(tab, automatic: true);
        }
    }

    private void ClearActivityButton_OnClick(object sender, RoutedEventArgs e)
    {
        ActivityList.Items.Clear();
    }

    private void ClearConsoleButton_OnClick(object sender, RoutedEventArgs e)
    {
        ConsoleTextBox.Clear();
    }

    private void ApplyShellTheme()
    {
        var light = _settings.ShellTheme switch
        {
            "Light" => true,
            "System" => IsWindowsLightTheme(),
            _ => false
        };

        if (light)
        {
            Resources["ShellBackgroundBrush"] = new SolidColorBrush(Color.FromRgb(0xEA, 0xEB, 0xED));
            Resources["PanelBackgroundBrush"] = new SolidColorBrush(Color.FromRgb(0xF2, 0xF3, 0xF5));
            Resources["PanelInnerBrush"] = new SolidColorBrush(Color.FromRgb(0xFF, 0xFF, 0xFF));
            Resources["PanelTextBrush"] = new SolidColorBrush(Color.FromRgb(0x20, 0x21, 0x24));
            Resources["PanelMutedBrush"] = new SolidColorBrush(Color.FromRgb(0x65, 0x68, 0x6D));
            Resources["PanelBorderBrush"] = new SolidColorBrush(Color.FromRgb(0xC9, 0xCB, 0xCF));
            Resources["TabBackgroundBrush"] = new SolidColorBrush(Color.FromRgb(0xE2, 0xE4, 0xE7));
            Resources["TabSelectedBrush"] = new SolidColorBrush(Color.FromRgb(0xFF, 0xFF, 0xFF));
        }
        else
        {
            Resources["ShellBackgroundBrush"] = new SolidColorBrush(Color.FromRgb(0x15, 0x17, 0x19));
            Resources["PanelBackgroundBrush"] = new SolidColorBrush(Color.FromRgb(0x19, 0x1B, 0x1D));
            Resources["PanelInnerBrush"] = new SolidColorBrush(Color.FromRgb(0x11, 0x13, 0x15));
            Resources["PanelTextBrush"] = new SolidColorBrush(Color.FromRgb(0xE5, 0xE7, 0xE9));
            Resources["PanelMutedBrush"] = new SolidColorBrush(Color.FromRgb(0x92, 0x96, 0x9B));
            Resources["PanelBorderBrush"] = new SolidColorBrush(Color.FromRgb(0x34, 0x37, 0x3A));
            Resources["TabBackgroundBrush"] = new SolidColorBrush(Color.FromRgb(0x20, 0x22, 0x25));
            Resources["TabSelectedBrush"] = new SolidColorBrush(Color.FromRgb(0x2A, 0x2D, 0x30));
        }
    }

    private static bool IsWindowsLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");

            return Convert.ToInt32(key?.GetValue("AppsUseLightTheme", 0)) != 0;
        }
        catch
        {
            return false;
        }
    }
}
