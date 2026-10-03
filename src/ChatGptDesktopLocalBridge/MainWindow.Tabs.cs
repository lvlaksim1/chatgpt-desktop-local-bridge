using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private async Task AddChatTabAsync(string url, bool select)
    {
        if (_webEnvironment is null)
        {
            return;
        }

        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps ||
            !(uri.Host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase) ||
              uri.Host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase)))
        {
            uri = new Uri("https://chatgpt.com/");
            url = uri.AbsoluteUri;
        }

        var browser = new WebView2
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch
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
            Foreground = new SolidColorBrush(Color.FromRgb(0xB8, 0xBB, 0xC0)),
            ToolTip = "Закрыть вкладку"
        };

        var header = new StackPanel
        {
            Orientation = Orientation.Horizontal
        };
        header.Children.Add(headerText);
        header.Children.Add(closeButton);

        var item = new TabItem
        {
            Header = header,
            Content = browser
        };

        var tab = new ChatTab
        {
            Browser = browser,
            Item = item,
            HeaderText = headerText,
            LastUrl = url
        };

        closeButton.Click += (_, _) => CloseChatTab(tab);

        _tabs.Add(tab);
        ChatTabs.Items.Add(item);

        await browser.EnsureCoreWebView2Async(_webEnvironment);

        browser.CoreWebView2.Settings.IsWebMessageEnabled = true;
        browser.CoreWebView2.Settings.AreDevToolsEnabled = true;

        browser.CoreWebView2.WebMessageReceived +=
            (_, e) => CoreWebView2_OnWebMessageReceived(tab, e);

        browser.CoreWebView2.DocumentTitleChanged +=
            (_, _) => Dispatcher.BeginInvoke(
                new Action(() => UpdateTabHeader(tab)));

        browser.CoreWebView2.NewWindowRequested += (_, e) =>
        {
            var target = e.Uri;
            e.Handled = true;

            Dispatcher.BeginInvoke(
                new Action(() => _ = AddChatTabAsync(target, select: true)));
        };

        browser.CoreWebView2.ContextMenuRequested += (_, e) =>
        {
            var link = e.ContextMenuTarget.LinkUri;
            if (string.IsNullOrWhiteSpace(link))
            {
                return;
            }

            var openInTab = _webEnvironment.CreateContextMenuItem(
                "Открыть в новой вкладке",
                null,
                CoreWebView2ContextMenuItemKind.Command);

            openInTab.CustomItemSelected += (_, _) =>
            {
                Dispatcher.BeginInvoke(
                    new Action(() => _ = AddChatTabAsync(link, select: true)));
            };

            e.MenuItems.Insert(0, openInTab);
        };

        browser.NavigationCompleted += async (_, e) =>
        {
            tab.NavigationReady = e.IsSuccess;
            tab.LastUrl = browser.Source?.AbsoluteUri ?? tab.LastUrl;
            UpdateTabHeader(tab);

            if (e.IsSuccess)
            {
                await ApplyChatBackgroundAsync(tab);

                if (!string.Equals(
                        tab.LastBootstrappedUrl,
                        tab.LastUrl,
                        StringComparison.Ordinal))
                {
                    tab.BridgeHost = null;
                    tab.BridgeReady = false;
                    tab.ReadyCompletion = null;

                    if (_settings.AutoInitializeBridge)
                    {
                        _ = EnsureBridgeForTabAsync(tab, automatic: true);
                    }
                }
            }

            if (ReferenceEquals(ActiveTab, tab))
            {
                SetStatus(e.IsSuccess
                    ? "ChatGPT готов"
                    : $"Ошибка навигации: {e.WebErrorStatus}");
            }
        };

        await browser.CoreWebView2.AddScriptToExecuteOnDocumentCreatedAsync(
            _adapterScript);

        browser.Source = uri;

        if (select)
        {
            ChatTabs.SelectedItem = item;
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

        _tabs.RemoveAt(index);
        ChatTabs.Items.Remove(tab.Item);
        tab.Browser.Dispose();

        if (ChatTabs.SelectedIndex < 0 && ChatTabs.Items.Count > 0)
        {
            ChatTabs.SelectedIndex = Math.Min(index, ChatTabs.Items.Count - 1);
        }
    }

    private void UpdateTabHeader(ChatTab tab)
    {
        var title = tab.Browser.CoreWebView2?.DocumentTitle;
        if (string.IsNullOrWhiteSpace(title))
        {
            title = "ChatGPT";
        }

        title = title.Replace(" | OpenAI", "", StringComparison.OrdinalIgnoreCase);

        if (title.Length > 28)
        {
            title = title[..27] + "…";
        }

        tab.HeaderText.Text = title;
    }

    private void ChatTabs_OnSelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        if (!_applicationReady)
        {
            return;
        }

        var tab = ActiveTab;
        if (tab is null)
        {
            return;
        }

        SetStatus(tab.BridgeReady
            ? $"Мост готов · {tab.BridgeHost?.SessionId[..8]}…"
            : "ChatGPT готов");

        if (_settings.AutoInitializeBridge &&
            tab.NavigationReady &&
            !tab.BridgeReady)
        {
            _ = EnsureBridgeForTabAsync(tab, automatic: true);
        }
    }

    private async Task ApplyChatBackgroundToAllTabsAsync()
    {
        foreach (var tab in _tabs)
        {
            await ApplyChatBackgroundAsync(tab);
        }
    }

    private async Task ApplyChatBackgroundAsync(ChatTab tab)
    {
        if (tab.Browser.CoreWebView2 is null)
        {
            return;
        }

        var color = NormalizeColor(_settings.ChatBackground);
        var colorJson = JsonSerializer.Serialize(color);

        var script = string.IsNullOrWhiteSpace(color)
            ? """
              (() => {
                document.getElementById('__local_bridge_chat_background')?.remove();
              })();
              """
            : $$"""
              (() => {
                let style = document.getElementById('__local_bridge_chat_background');
                if (!style) {
                  style = document.createElement('style');
                  style.id = '__local_bridge_chat_background';
                  document.head.appendChild(style);
                }
                const color = {{colorJson}};
                style.textContent =
                  'html, body, #__next { background-color: ' + color + ' !important; }' +
                  'main { background-color: ' + color + ' !important; }' +
                  '[class*="bg-token-main-surface-primary"] { background-color: ' + color + ' !important; }' +
                  '[class*="bg-token-main-surface-secondary"] { background-color: ' + color + ' !important; }';
              })();
              """;

        try
        {
            await tab.Browser.ExecuteScriptAsync(script);
        }
        catch
        {
            // Appearance customization must never interfere with navigation.
        }
    }

    private static string NormalizeColor(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        var normalized = value.Trim().ToUpperInvariant();
        if (normalized.Length == 7 &&
            normalized[0] == '#' &&
            normalized.Skip(1).All(Uri.IsHexDigit))
        {
            return normalized;
        }

        return string.Empty;
    }
}
