using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
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
                BuildChatThemeBootstrapScript());

            await tab.Browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
                _adapterScript);

            tab.Browser.CoreWebView2.WebMessageReceived +=
                (_, e) => CoreWebView2_OnWebMessageReceived(tab, e);

            tab.Browser.CoreWebView2.DocumentTitleChanged +=
                (_, _) => Dispatcher.BeginInvoke(
                    new Action(() => UpdateTabHeader(tab)));

            tab.Browser.CoreWebView2.NewWindowRequested += (_, e) =>
            {
                var target = e.Uri;
                e.Handled = true;

                Dispatcher.BeginInvoke(
                    new Action(() =>
                        _ = AddChatTabAsync(
                            target,
                            select: true,
                            allowDuplicate: false)));
            };

            tab.Browser.CoreWebView2.ContextMenuRequested +=
                async (_, e) => await AddOpenInTabContextMenuAsync(tab, e);

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

                if (ReferenceEquals(ActiveTab, tab))
                {
                    ShowSelectedTab();
                    SetStatus("Загрузка ChatGPT…");
                }
            };

            tab.Browser.NavigationCompleted += async (_, e) =>
            {
                tab.NavigationReady = e.IsSuccess;
                tab.LastUrl = tab.Browser.Source?.AbsoluteUri ?? tab.LastUrl;
                UpdateTabHeader(tab);

                if (e.IsSuccess)
                {
                    await ApplyUnifiedThemeToTabAsync(tab);
                    await Task.Delay(120);
                    tab.PageReady = true;
                    SetTabState(tab, "idle");

                    if (ReferenceEquals(ActiveTab, tab))
                    {
                        ShowSelectedTab();
                        SetStatus("ChatGPT готов");

                        if (_settings.AutoInitializeBridge)
                        {
                            ScheduleBridgeStart(
                                tab,
                                TimeSpan.FromMilliseconds(300));
                        }
                    }
                }
                else
                {
                    tab.PageReady = false;
                    SetTabState(tab, "error");

                    if (ReferenceEquals(ActiveTab, tab))
                    {
                        ShowSelectedTab();
                        SetStatus($"Ошибка навигации: {e.WebErrorStatus}");
                    }
                }
            };

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

    private async Task AddOpenInTabContextMenuAsync(
        ChatTab tab,
        CoreWebView2ContextMenuRequestedEventArgs e)
    {
        var deferral = e.GetDeferral();

        try
        {
            var target = e.ContextMenuTarget.LinkUri;

            if (string.IsNullOrWhiteSpace(target))
            {
                try
                {
                    var raw = await tab.Browser.ExecuteScriptAsync(
                        "window.__localBridge?.contextNavigationTarget?.() ?? null");

                    if (!string.IsNullOrWhiteSpace(raw) && raw != "null")
                    {
                        target = JsonSerializer.Deserialize<string>(raw);
                    }
                }
                catch
                {
                }
            }

            if (!AppSettings.IsChatUrl(target))
            {
                return;
            }

            var resolved = target!;
            var openInTab = _webEnvironment!.CreateContextMenuItem(
                "Открыть в новой вкладке",
                null,
                CoreWebView2ContextMenuItemKind.Command);

            openInTab.CustomItemSelected += (_, _) =>
            {
                Dispatcher.BeginInvoke(
                    new Action(() =>
                        _ = AddChatTabAsync(
                            resolved,
                            select: false,
                            allowDuplicate: false)));
            };

            e.MenuItems.Insert(0, openInTab);
        }
        finally
        {
            deferral.Complete();
        }
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
            tab.Container.Visibility = selected
                ? Visibility.Visible
                : Visibility.Hidden;

            if (!selected)
            {
                tab.Browser.Visibility = Visibility.Hidden;
                continue;
            }

            if (tab.PageReady)
            {
                tab.LoadingPanel.Visibility = Visibility.Collapsed;
                tab.Browser.Visibility = Visibility.Visible;
            }
            else
            {
                tab.Browser.Visibility = Visibility.Hidden;
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
            if (!root) return;

            root.style.backgroundColor = values.base;
            root.style.colorScheme = values.scheme;

            const vars = {
              '--main-surface-primary': values.base,
              '--main-surface-secondary': values.surface,
              '--main-surface-tertiary': values.alt,
              '--main-surface-background': values.base,
              '--sidebar-surface-primary': values.surface,
              '--sidebar-surface-secondary': values.alt,
              '--sidebar-surface-tertiary': values.selected,
              '--composer-surface': values.surface,
              '--message-surface': values.base,
              '--text-primary': values.text,
              '--text-secondary': values.muted
            };

            for (const [name, value] of Object.entries(vars)) {
              root.style.setProperty(name, value, 'important');
            }

            let style = document.getElementById('__local_bridge_unified_theme');
            if (!style) {
              style = document.createElement('style');
              style.id = '__local_bridge_unified_theme';
              root.appendChild(style);
            }

            style.textContent =
              'html, body, #__next, main, [role="main"] {' +
              'background-color:' + values.base + ' !important;}' +
              'aside, nav, [class*="sidebar"], [class*="bg-token-sidebar-surface-primary"] {' +
              'background-color:' + values.surface + ' !important;}' +
              '[class*="bg-token-sidebar-surface-secondary"], [class*="bg-token-main-surface-secondary"] {' +
              'background-color:' + values.alt + ' !important;}' +
              '[class*="bg-token-main-surface-primary"], [class*="bg-black"], [class*="dark:bg-black"] {' +
              'background-color:' + values.base + ' !important;}' +
              'form, [data-testid*="composer"], [class*="composer"] {' +
              'background-color:' + values.surface + ' !important;}';

            if (document.body) {
              document.body.style.backgroundColor = values.base;
            }
          };

          apply();

          if (!document.body) {
            const observer = new MutationObserver(() => {
              if (document.body) {
                apply();
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

    private static string NormalizeNavigationUrl(string value)
    {
        if (!AppSettings.IsChatUrl(value))
        {
            return "https://chatgpt.com/";
        }

        return AppSettings.CanonicalizeUrl(value);
    }
}
