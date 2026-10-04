using System.Windows;

namespace ChatGptDesktopLocalBridge;

public partial class MainWindow
{
    private void ScheduledTaskProbeButton_OnClick(
        object sender,
        RoutedEventArgs e)
    {
        var tab = ActiveTab;

        if (tab?.Browser.CoreWebView2 is null || !tab.PageReady)
        {
            SetStatus("Tasks Probe: активная вкладка ChatGPT ещё не готова.");
            return;
        }

        try
        {
            var window = new ScheduledTaskTransportProbeWindow(tab.Browser)
            {
                Owner = this
            };

            window.Show();
            SetStatus("Scheduled Task Transport Probe открыт.");
        }
        catch (Exception ex)
        {
            SetStatus($"Tasks Probe: {ex.Message}");
        }
    }
}
