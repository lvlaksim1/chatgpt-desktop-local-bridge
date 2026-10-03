using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private Task AddChatTabAsync(
        string url,
        bool select,
        bool allowDuplicate)
    {
        var normalized = NormalizeNavigationUrl(url);

        if (!allowDuplicate)
        {
            var existing = _tabs.FirstOrDefault(tab =>
                string.Equals(
                    AppSettings.CanonicalizeUrl(
                        tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl),
                    AppSettings.CanonicalizeUrl(normalized),
                    StringComparison.OrdinalIgnoreCase));

            if (existing is not null)
            {
                if (select)
                {
                    ChatTabs.SelectedItem = existing.Item;
                    ShowSelectedTab();
                }

                return Task.CompletedTask;
            }
        }

        if (_webEnvironment is null)
        {
            return Task.CompletedTask;
        }

        var palette = ThemePalette.FromBase(_settings.ThemeColor);
        var browser = new WebView2
        {
            Visibility = Visibility.Hidden,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch
        };

        ApplyNativeBrowserBackground(browser, palette.Base);

        var loadingText = new TextBlock
        {
            Text = "Загрузка ChatGPT…",
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            Foreground = Brush(palette.Muted),
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center
        };

        var loadingPanel = new Border
        {
            Background = Brush(palette.Base),
            Child = loadingText
        };

        var container = new Grid
        {
            Visibility = Visibility.Hidden,
            Background = Brush(palette.Base)
        };
        container.Children.Add(browser);
        container.Children.Add(loadingPanel);

        var statusGlyph = new TextBlock
        {
            Text = "●",
            Margin = new Thickness(0, 0, 6, 0),
            Foreground = Brushes.Gray,
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 10
        };

        var headerText = new TextBlock
        {
            Text = "ChatGPT",
            VerticalAlignment = VerticalAlignment.Center,
            MaxWidth = 180,
            TextTrimming = TextTrimming.CharacterEllipsis
        };

        var closeButton = new Button
        {
            Content = "×",
            Margin = new Thickness(8, 0, 0, 0),
            Padding = new Thickness(4, 0, 4, 0),
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = Brush(palette.Muted),
            ToolTip = "Закрыть вкладку"
        };

        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal
        };
        header.Children.Add(statusGlyph);
        header.Children.Add(headerText);
        header.Children.Add(closeButton);

        var item = new TabItem { Header = header };

        var tab = new ChatTab
        {
            Browser = browser,
            Container = container,
            LoadingPanel = loadingPanel,
            HeaderText = headerText,
            StatusGlyph = statusGlyph,
            Item = item,
            LastUrl = normalized
        };

        closeButton.Click += (_, _) => CloseChatTab(tab);

        _tabs.Add(tab);
        ChatTabs.Items.Add(item);
        BrowserHost.Children.Add(container);

        if (select)
        {
            ChatTabs.SelectedItem = item;
            ShowSelectedTab();
        }

        _ = InitializeChatTabAsync(tab, normalized);
        return Task.CompletedTask;
    }

    private async Task InitializeChatTabAsync(
        ChatTab tab,
        string url)
    {
        try
        {
            SetTabState(tab, "loading");

            await tab.Browser.EnsureCoreWebView2Async(_webEnvironment);

            tab.Browser.CoreWebView2.Settings.IsWebMessageEnabled = true;
            tab.Browser.CoreWebView2.Settings.AreDevToolsEnabled = true;

            await tab.Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                BuildVisualBootstrapScript());

            await tab.Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                BuildChatThemeBootstrapScript());

            await tab.Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                _adapterScript);

            tab.Browser.CoreWebView2.WebMessageReceived +=
                (_, e) => CoreWebView2_OnWebMessageReceived(tab, e);

            tab.Browser.CoreWebView2.DocumentTitleChanged +=
                (_, _) => Dispatcher.BeginInvoke(
                    new Action(() => UpdateTabHeader(tab)));

            // Leave NewWindowRequested untouched so ordinary clicks, target=_blank
            // navigation and downloads keep native WebView2/site behavior.
            // Opening in our own tab strip is an explicit context-menu action only.
            tab.Browser.CoreWebView2.ContextMenuRequested +=
                (_, e) => AddOpenInTabContextMenu(tab, e);

            tab.Browser.NavigationStarting += (_, _) =>
            {
                tab.NavigationReady = false;
                tab.PageReady = false;
                tab.BridgeReady = false;
                tab.BridgeHost = null;
                tab.ReadyCompletion = null;
                tab.LastBootstrappedUrl = null;
                tab.BridgeRetryCts?.Cancel();
                tab.BridgeRetryCts = null;
                SetTabState(tab, "loading");
                tab.LoadingPanel.Visibility = Visibility.Visible;
                _ = ArmPaintShieldAsync(tab, loading: true);

                if (ReferenceEquals(ActiveTab, tab))
                {
                    SetStatus("Загрузка ChatGPT…");
                }
            };

            tab.Browser.NavigationCompleted += async (_, e) =>
            {
                tab.NavigationReady = e.IsSuccess;
                tab.LastUrl = tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl;
                UpdateTabHeader(tab);

                if (!e.IsSuccess)
                {
                    tab.PageReady = false;
                    SetTabState(tab, "error");
                    tab.LoadingPanel.Visibility = Visibility.Collapsed;
                    await ReleasePaintShieldAsync(tab);

                    if (ReferenceEquals(ActiveTab, tab))
                    {
                        SetStatus($"Ошибка навигации: {e.WebErrorStatus}");
                    }

                    return;
                }

                await WaitForVisualReadyAsync(
                    tab,
                    TimeSpan.FromSeconds(12));

                await ApplyUnifiedThemeToTabAsync(tab);
                await Task.Delay(80);

                tab.PageReady = true;
                SetTabState(tab, "idle");
                tab.LoadingPanel.Visibility = Visibility.Collapsed;

                if (ReferenceEquals(ActiveTab, tab))
                {
                    await ReleasePaintShieldAfterRenderAsync(tab);
                    SetStatus("ChatGPT готов");

                    if (_settings.AutoInitializeBridge)
                    {
                        ScheduleBridgeStart(
                            tab,
                            TimeSpan.FromMilliseconds(250));
                    }
                }
                else
                {
                    await ArmPaintShieldAsync(tab, loading: false);
                }
            };

            // Keep the real WebView alive and painted. The page-owned paint shield
            // masks navigation/render transitions without WebView2CompositionControl.
            tab.Browser.Visibility = Visibility.Visible;
            tab.Browser.Source = new Uri(url);
        }
        catch (Exception ex)
        {
            tab.PageReady = false;
            SetTabState(tab, "error");

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus($"Ошибка вкладки: {ex.Message}");
                ShowSelectedTab();
            }
        }
    }

    private void AddOpenInTabContextMenu(
        ChatTab tab,
        CoreWebView2ContextMenuRequestedEventArgs e)
    {
        try
        {
            string? target = null;

            if (DateTimeOffset.Now - tab.ContextNavigationAt < TimeSpan.FromSeconds(2) &&
                AppSettings.IsChatUrl(tab.ContextNavigationTarget))
            {
                target = tab.ContextNavigationTarget;
            }

            if (!AppSettings.IsChatUrl(target) ||
                _webEnvironment is null)
            {
                return;
            }

            var resolved = AppSettings.CanonicalizeUrl(target!);
            var openInTab = _webEnvironment.CreateContextMenuItem(
                "Открыть в новой вкладке",
                null,
                CoreWebView2ContextMenuItemKind.Command);

            openInTab.CustomItemSelected += (_, _) =>
            {
                try
                {
                    Dispatcher.BeginInvoke(
                        new Action(() =>
                            _ = AddChatTabAsync(
                                resolved,
                                select: false,
                                allowDuplicate: false)));
                }
                catch
                {
                    // Context-menu enhancement is optional.
                }
            };

            e.MenuItems.Insert(0, openInTab);
        }
        catch
        {
            // Never let optional context-menu integration terminate the app.
        }
    }

    private async Task WaitForVisualReadyAsync(
        ChatTab tab,
        TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        var stableSamples = 0;

        while (DateTime.UtcNow < deadline)
        {
            try
            {
                var raw = await tab.Browser.ExecuteScriptAsync(
                    """
                    (() => ({
                      readyState: document.readyState,
                      body: Boolean(document.body),
                      width: document.documentElement?.clientWidth ?? 0,
                      height: document.documentElement?.clientHeight ?? 0,
                      surface: Boolean(
                        document.querySelector(
                          "#prompt-textarea, textarea[data-testid='prompt-textarea'], " +
                          "div[contenteditable='true'][data-testid='prompt-textarea'], " +
                          "div[contenteditable='true'][role='textbox'], " +
                          "main, [role='main'], form"
                        )
                      )
                    }))()
                    """);

                using var document = JsonDocument.Parse(raw);
                var root = document.RootElement;

                var complete =
                    root.TryGetProperty("readyState", out var state) &&
                    state.ValueKind == JsonValueKind.String &&
                    string.Equals(
                        state.GetString(),
                        "complete",
                        StringComparison.OrdinalIgnoreCase);

                var body =
                    root.TryGetProperty("body", out var bodyElement) &&
                    bodyElement.ValueKind == JsonValueKind.True;

                var surface =
                    root.TryGetProperty("surface", out var surfaceElement) &&
                    surfaceElement.ValueKind == JsonValueKind.True;

                var width =
                    root.TryGetProperty("width", out var widthElement) &&
                    widthElement.TryGetInt32(out var parsedWidth)
                        ? parsedWidth
                        : 0;

                var height =
                    root.TryGetProperty("height", out var heightElement) &&
                    heightElement.TryGetInt32(out var parsedHeight)
                        ? parsedHeight
                        : 0;

                if (complete && body && surface && width > 100 && height > 100)
                {
                    stableSamples++;
                    if (stableSamples >= 3)
                    {
                        return;
                    }
                }
                else
                {
                    stableSamples = 0;
                }
            }
            catch
            {
                stableSamples = 0;
            }

            await Task.Delay(150);
        }
    }

    private async Task ArmPaintShieldAsync(
        ChatTab tab,
        bool loading)
    {
        if (tab.Browser.CoreWebView2 is null)
        {
            return;
        }

        try
        {
            await tab.Browser.ExecuteScriptAsync(
                loading
                    ? "window.__desktopShellVisual?.show?.('loading')"
                    : "window.__desktopShellVisual?.show?.('switch')");
        }
        catch
        {
            // Visual masking is optional and must never affect app survival.
        }
    }

    private async Task ReleasePaintShieldAsync(ChatTab tab)
    {
        if (tab.Browser.CoreWebView2 is null)
        {
            return;
        }

        try
        {
            await tab.Browser.ExecuteScriptAsync(
                "window.__desktopShellVisual?.hide?.()");
        }
        catch
        {
            // Visual masking is optional and must never affect app survival.
        }
    }

    private async Task ReleasePaintShieldAfterRenderAsync(ChatTab tab)
    {
        try
        {
            await Dispatcher.Yield(DispatcherPriority.Render);
            await Task.Delay(40);
            await ReleasePaintShieldAsync(tab);
        }
        catch
        {
            // Do not let a visual transition affect tab/navigation reliability.
        }
    }

    private string BuildVisualBootstrapScript()
    {
        var p = ThemePalette.FromBase(_settings.ThemeColor);
        var config = JsonSerializer.Serialize(new
        {
            background = p.Base,
            foreground = p.Muted
        });
        var configLiteral = JsonSerializer.Serialize(config);

        return """
        (() => {
          const cfg = JSON.parse(CONFIG_PLACEHOLDER);

          const ensureStyle = () => {
            const root = document.documentElement;
            if (!root) return false;

            root.style.backgroundColor = cfg.background;

            let style = document.getElementById('__desktop_shell_visual_style');
            if (!style) {
              style = document.createElement('style');
              style.id = '__desktop_shell_visual_style';
              root.appendChild(style);
            }

            style.textContent =
              '#__desktop_shell_paint_shield{' +
              'position:fixed!important;inset:0!important;z-index:2147483647!important;' +
              'display:flex;align-items:center;justify-content:center;' +
              'background:var(--desktop-shell-bg)!important;' +
              'color:var(--desktop-shell-fg)!important;' +
              'font:600 16px "Segoe UI",sans-serif!important;' +
              'pointer-events:auto!important;}' +
              '#__desktop_shell_paint_shield[data-mode="switch"]{font-size:0!important;}';

            root.style.setProperty('--desktop-shell-bg', cfg.background);
            root.style.setProperty('--desktop-shell-fg', cfg.foreground);
            return true;
          };

          const ensureShield = () => {
            if (!ensureStyle() || !document.body) return null;

            let shield = document.getElementById('__desktop_shell_paint_shield');
            if (!shield) {
              shield = document.createElement('div');
              shield.id = '__desktop_shell_paint_shield';
              shield.setAttribute('aria-hidden', 'true');
              document.body.appendChild(shield);
            }
            return shield;
          };

          const show = mode => {
            const shield = ensureShield();
            if (!shield) return false;
            shield.dataset.mode = mode === 'loading' ? 'loading' : 'switch';
            shield.textContent = mode === 'loading' ? 'Загрузка ChatGPT…' : '';
            shield.style.display = 'flex';
            return true;
          };

          const hide = () => {
            const shield = document.getElementById('__desktop_shell_paint_shield');
            if (shield) shield.style.display = 'none';
            return true;
          };

          const setTheme = (background, foreground) => {
            const root = document.documentElement;
            if (!root) return false;
            root.style.setProperty('--desktop-shell-bg', background);
            root.style.setProperty('--desktop-shell-fg', foreground);
            root.style.backgroundColor = background;
            return true;
          };

          window.__desktopShellVisual = { show, hide, setTheme };

          if (!show('loading')) {
            const observer = new MutationObserver(() => {
              if (show('loading')) observer.disconnect();
            });
            observer.observe(document, { childList: true, subtree: true });
          }
        })();
        """.Replace("CONFIG_PLACEHOLDER", configLiteral);
    }

    private void CloseChatTab(ChatTab tab)
    {
        if (_tabs.Count <= 1)
        {
            return;
        }

        var index = _tabs.IndexOf(tab);
        if (index < 0)
        {
            return;
        }

        tab.BridgeRetryCts?.Cancel();
        _tabs.RemoveAt(index);
        ChatTabs.Items.Remove(tab.Item);
        BrowserHost.Children.Remove(tab.Container);
        tab.Browser.Dispose();

        if (ChatTabs.SelectedIndex < 0 && ChatTabs.Items.Count > 0)
        {
            ChatTabs.SelectedIndex = Math.Min(index, ChatTabs.Items.Count - 1);
        }

        ShowSelectedTab();
        SaveRuntimeSettings();
    }

    private void UpdateTabHeader(ChatTab tab)
    {
        var title = tab.Browser.CoreWebView2?.DocumentTitle;
        if (string.IsNullOrWhiteSpace(title))
        {
            title = "ChatGPT";
        }

        title = title.Replace(
            " | OpenAI",
            "",
            StringComparison.OrdinalIgnoreCase);

        if (title.Length > 30)
        {
            title = title[..29] + "…";
        }

        tab.HeaderText.Text = title;
    }

    private void ChatTabs_OnSelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!_applicationReady && _tabs.Count == 0)
        {
            return;
        }

        ShowSelectedTab();

        var tab = ActiveTab;
        if (tab is null)
        {
            return;
        }

        if (!tab.PageReady)
        {
            SetStatus("Загрузка ChatGPT…");
            return;
        }

        SetStatus(tab.BridgeReady && tab.BridgeHost is not null
            ? $"Мост готов · {tab.BridgeHost.SessionId[..8]}…"
            : "ChatGPT готов");

        if (_settings.AutoInitializeBridge && !tab.BridgeReady)
        {
            ScheduleBridgeStart(
                tab,
                TimeSpan.FromMilliseconds(150));
        }

        SaveRuntimeSettings();
    }

    private void ShowSelectedTab()
    {
        var active = ActiveTab;

        foreach (var tab in _tabs)
        {
            var selected = ReferenceEquals(tab, active);

            if (!selected &&
                tab.Container.Visibility == Visibility.Visible &&
                tab.PageReady)
            {
                _ = ArmPaintShieldAsync(tab, loading: false);
            }

            // Keep each initialized WebView itself alive/visible. Only its WPF
            // parent is switched, preserving background preload and warm state.
            tab.Container.Visibility = selected
                ? Visibility.Visible
                : Visibility.Hidden;

            if (!selected)
            {
                continue;
            }

            tab.Browser.Visibility = Visibility.Visible;

            if (tab.PageReady)
            {
                tab.LoadingPanel.Visibility = Visibility.Collapsed;
                _ = ReleasePaintShieldAfterRenderAsync(tab);
            }
            else
            {
                tab.LoadingPanel.Visibility = Visibility.Visible;
            }
        }
    }

    private void SetTabState(ChatTab tab, string state)
    {
        tab.StatusGlyph.Foreground = state switch
        {
            "ready" => Brushes.LimeGreen,
            "waiting" => Brushes.Goldenrod,
            "error" => Brushes.IndianRed,
            "loading" => Brushes.SteelBlue,
            _ => Brushes.Gray
        };
    }

    private async Task ApplyUnifiedThemeToAllTabsAsync()
    {
        foreach (var tab in _tabs)
        {
            var palette = ThemePalette.FromBase(_settings.ThemeColor);
            tab.Container.Background = Brush(palette.Base);
            tab.LoadingPanel.Background = Brush(palette.Base);
            ApplyNativeBrowserBackground(tab.Browser, palette.Base);

            if (tab.LoadingPanel.Child is TextBlock text)
            {
                text.Foreground = Brush(palette.Muted);
            }

            await ApplyUnifiedThemeToTabAsync(tab);
        }
    }

    private async Task ApplyUnifiedThemeToTabAsync(ChatTab tab)
    {
        if (tab.Browser.CoreWebView2 is null)
        {
            return;
        }

        try
        {
            await tab.Browser.ExecuteScriptAsync(
                BuildChatThemeBootstrapScript());

            var p = ThemePalette.FromBase(_settings.ThemeColor);
            var background = JsonSerializer.Serialize(p.Base);
            var foreground = JsonSerializer.Serialize(p.Muted);
            await tab.Browser.ExecuteScriptAsync(
                $"window.__desktopShellVisual?.setTheme?.({background}, {foreground})");
        }
        catch
        {
        }
    }

    private string BuildChatThemeBootstrapScript()
    {
        var p = ThemePalette.FromBase(_settings.ThemeColor);
        var values = JsonSerializer.Serialize(new
        {
            @base = p.Base,
            surface = p.Surface,
            alt = p.SurfaceAlt,
            deep = p.SurfaceDeep,
            selected = p.Selected,
            border = p.Border,
            text = p.Text,
            muted = p.Muted,
            scheme = p.IsLight ? "light" : "dark"
        });

        var valuesLiteral = JsonSerializer.Serialize(values);

        return """
        (() => {
          const values = JSON.parse(VALUE_PLACEHOLDER);

          const apply = () => {
            const root = document.documentElement;
            if (!root) return false;

            const targets = [root, document.body].filter(Boolean);
            const vars = {
              '--main-surface-primary': values.base,
              '--main-surface-secondary': values.surface,
              '--main-surface-tertiary': values.alt,
              '--main-surface-background': values.base,
              '--main-surface-primary-inverse': values.text,
              '--sidebar-surface-primary': values.surface,
              '--sidebar-surface-secondary': values.alt,
              '--sidebar-surface-tertiary': values.selected,
              '--composer-surface': values.surface,
              '--composer-surface-primary': values.surface,
              '--composer-surface-secondary': values.alt,
              '--message-surface': values.base,
              '--text-primary': values.text,
              '--text-secondary': values.muted,
              '--border-light': values.border,
              '--border-medium': values.border,
              '--border-heavy': values.border
            };

            for (const target of targets) {
              target.style.backgroundColor = values.base;
              target.style.colorScheme = values.scheme;

              for (const [name, value] of Object.entries(vars)) {
                target.style.setProperty(name, value, 'important');
              }
            }

            let style = document.getElementById('__local_bridge_unified_theme');
            if (!style) {
              style = document.createElement('style');
              style.id = '__local_bridge_unified_theme';
              root.appendChild(style);
            }

            style.textContent =
              'html,body{min-height:100%!important;background:' + values.base + ' !important;}' +
              'body{margin:0!important;color:' + values.text + ' !important;}' +
              'body>div,#__next,#__next>div{min-height:100vh!important;background-color:' + values.base + ' !important;}' +
              'main,[role="main"],[data-testid="conversation-turns"],' +
              '[class*="bg-token-main-surface-primary"],[class*="main-surface-primary"],' +
              '[class*="bg-black"],[class*="dark:bg-black"]{' +
                'background-color:' + values.base + ' !important;}' +
              'aside,nav,[class*="sidebar"],[class*="bg-token-sidebar-surface-primary"]{' +
                'background-color:' + values.surface + ' !important;}' +
              '[class*="bg-token-sidebar-surface-secondary"],' +
              '[class*="bg-token-main-surface-secondary"],[class*="main-surface-secondary"]{' +
                'background-color:' + values.alt + ' !important;}' +
              'form,[data-testid*="composer"],[class*="composer"],[class*="composer-parent"]{' +
                'background-color:' + values.surface + ' !important;}' +
              '[role="dialog"],[role="menu"],[role="listbox"],' +
              '[data-radix-popper-content-wrapper]>*,[class*="popover"],[class*="modal"]{' +
                'background-color:' + values.surface + ' !important;color:' + values.text + ' !important;}' +
              '[class*="border-token"],hr{border-color:' + values.border + ' !important;}';

            if (document.body) {
              document.body.style.minHeight = '100vh';
              document.body.style.backgroundColor = values.base;
            }

            window.__desktopShellVisual?.setTheme?.(
              values.base,
              values.muted
            );

            return true;
          };

          apply();

          if (!document.body) {
            const observer = new MutationObserver(() => {
              if (document.body && apply()) {
                observer.disconnect();
              }
            });
            observer.observe(document.documentElement, {
              childList: true,
              subtree: true
            });
          }
        })();
        """.Replace("VALUE_PLACEHOLDER", valuesLiteral);
    }

    private static void ApplyNativeBrowserBackground(
        WebView2 browser,
        string color)
    {
        try
        {
            var parsed = ThemePalette.Parse(color);
            browser.DefaultBackgroundColor =
                System.Drawing.Color.FromArgb(
                    parsed.A,
                    parsed.R,
                    parsed.G,
                    parsed.B);
        }
        catch
        {
            // Native background is cosmetic only.
        }
    }

    private static string NormalizeNavigationUrl(string value)
    {
        if (!AppSettings.IsChatUrl(value))
        {
            return "https://chatgpt.com/";
        }

        return AppSettings.CanonicalizeUrl(value);
    }
}
