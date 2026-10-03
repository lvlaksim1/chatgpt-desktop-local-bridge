using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using ChatGptDesktopLocalBridge.Bridge;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private readonly string _appDataRoot;
    private readonly AppSettings _settings;
    private readonly List<ChatTab> _tabs = new();

    private CoreWebView2Environment? _webEnvironment;
    private string _adapterScript = string.Empty;
    private UpdateCandidate? _availableUpdate;
    private DispatcherTimer? _updateTimer;
    private bool _applicationReady;

    private sealed class ChatTab
    {
        public required WebView2 Browser { get; init; }
        public required Grid Container { get; init; }
        public required Border LoadingPanel { get; init; }
        public required TextBlock HeaderText { get; init; }
        public required TextBlock StatusGlyph { get; init; }
        public required TabItem Item { get; init; }
        public required string LastUrl { get; set; }

        public BridgeHost? BridgeHost { get; set; }
        public TaskCompletionSource<bool>? ReadyCompletion { get; set; }
        public CancellationTokenSource? BridgeRetryCts { get; set; }
        public bool BridgeReady { get; set; }
        public bool NavigationReady { get; set; }
        public bool PageReady { get; set; }
        public int BridgeRetryCount { get; set; }
        public string? LastBootstrappedUrl { get; set; }
        public string? ContextNavigationTarget { get; set; }
        public DateTimeOffset ContextNavigationAt { get; set; }
    }

    public MainWindow()
    {
        UpdateService.ReconcilePendingUpdate();
        _settings = AppSettings.Load();

        InitializeComponent();

        _appDataRoot = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "ChatGptDesktopLocalBridge");

        VersionText.Text = LoadDisplayVersion();
        BridgePanelColumn.Width = new GridLength(_settings.RightPanelWidth);
        Width = _settings.WindowWidth;
        Height = _settings.WindowHeight;

        if (_settings.WindowLeft.HasValue) Left = _settings.WindowLeft.Value;
        if (_settings.WindowTop.HasValue) Top = _settings.WindowTop.Value;

        ApplyUnifiedTheme();

        SourceInitialized += MainWindow_OnSourceInitialized;
        StateChanged += (_, _) => UpdateMaximizeButton();
        Closing += MainWindow_OnClosing;
        Loaded += async (_, _) => await InitializeApplicationAsync();
    }

    private ChatTab? ActiveTab =>
        ChatTabs.SelectedItem is TabItem item
            ? _tabs.FirstOrDefault(tab => ReferenceEquals(tab.Item, item))
            : null;

    private static string LoadDisplayVersion()
    {
        var identity = UpdateService.LoadInstalledIdentity();
        if (!string.IsNullOrWhiteSpace(identity?.AppVersion))
        {
            return $"v{identity.AppVersion}";
        }

        return $"v{typeof(MainWindow).Assembly.GetName().Version?.ToString() ?? "dev"}";
    }

    private async Task InitializeApplicationAsync()
    {
        try
        {
            Directory.CreateDirectory(_appDataRoot);
            SetStatus("Подготовка ChatGPT…");

            _webEnvironment = await CoreWebView2Environment.CreateAsync(
                userDataFolder: Path.Combine(_appDataRoot, "WebView2"));

            _adapterScript = await File.ReadAllTextAsync(
                Path.Combine(AppContext.BaseDirectory, "Web", "bridge-adapter.js"));

            var savedUrls = _settings.TabUrls.ToList();
            var selectedIndex = Math.Clamp(
                _settings.SelectedTabIndex,
                0,
                Math.Max(savedUrls.Count - 1, 0));

            for (var i = 0; i < savedUrls.Count; i++)
            {
                await AddChatTabAsync(
                    savedUrls[i],
                    select: i == selectedIndex,
                    allowDuplicate: false);
            }

            if (_tabs.Count == 0)
            {
                await AddChatTabAsync(
                    "https://chatgpt.com/",
                    select: true,
                    allowDuplicate: true);
            }

            _applicationReady = true;
            ShowSelectedTab();

            _ = CheckForUpdatesAsync(quiet: true);
            StartUpdatePolling();
        }
        catch (Exception ex)
        {
            SetStatus($"Ошибка запуска: {ex.Message}");
        }
    }

    private void MainWindow_OnClosing(
        object? sender,
        System.ComponentModel.CancelEventArgs e)
    {
        SaveRuntimeSettings();

        foreach (var tab in _tabs)
        {
            tab.BridgeRetryCts?.Cancel();
            tab.Browser.Dispose();
        }
    }

    private void SaveRuntimeSettings()
    {
        if (BridgePanelColumn.ActualWidth > 0)
        {
            _settings.RightPanelWidth =
                Math.Clamp(BridgePanelColumn.ActualWidth, 260, 760);
        }

        _settings.SelectedTabIndex = Math.Max(ChatTabs.SelectedIndex, 0);
        _settings.TabUrls = _tabs
            .Select(tab => AppSettings.CanonicalizeUrl(
                tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl))
            .Distinct(StringComparer.OrdinalIgnoreCase)
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
        => StatusText.Text = message;

    private void ReloadButton_OnClick(object sender, RoutedEventArgs e)
        => ActiveTab?.Browser.Reload();

    private async void NewChatButton_OnClick(object sender, RoutedEventArgs e)
        => await AddChatTabAsync(
            "https://chatgpt.com/",
            select: true,
            allowDuplicate: true);

    private async void SettingsButton_OnClick(object sender, RoutedEventArgs e)
    {
        var window = new SettingsWindow(_settings) { Owner = this };
        if (window.ShowDialog() != true)
        {
            return;
        }

        _settings.ThemeColor = window.SelectedThemeColor;
        _settings.AutoInitializeBridge =
            window.SelectedAutoInitializeBridge;
        _settings.Save();

        ApplyUnifiedTheme();
        await ApplyUnifiedThemeToAllTabsAsync();
    }

    private void ClearActivityButton_OnClick(object sender, RoutedEventArgs e)
        => ActivityList.Items.Clear();

    private void ClearConsoleButton_OnClick(object sender, RoutedEventArgs e)
        => ConsoleTextBox.Clear();

    private void ApplyUnifiedTheme()
    {
        var palette = ThemePalette.FromBase(_settings.ThemeColor);

        Resources["ShellBackgroundBrush"] = Brush(palette.Base);
        Resources["PanelBackgroundBrush"] = Brush(palette.Surface);
        Resources["PanelAltBrush"] = Brush(palette.SurfaceAlt);
        Resources["PanelInnerBrush"] = Brush(palette.SurfaceDeep);
        Resources["TopBarBrush"] = Brush(palette.TopBar);
        Resources["PanelBorderBrush"] = Brush(palette.Border);
        Resources["SelectedBrush"] = Brush(palette.Selected);
        Resources["ButtonBrush"] = Brush(palette.Button);
        Resources["ButtonHoverBrush"] = Brush(palette.ButtonHover);
        Resources["PanelTextBrush"] = Brush(palette.Text);
        Resources["PanelMutedBrush"] = Brush(palette.Muted);
    }

    private static SolidColorBrush Brush(string value)
        => new(ThemePalette.Parse(value));
}
