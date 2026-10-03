using System.Windows;
using System.Windows.Input;

namespace ChatGptDesktopLocalBridge;

public partial class UpdateWindow
{
    public UpdateWindow(UpdateCandidate candidate)
    {
        InitializeComponent();

        TargetText.Text = $"{candidate.CurrentTag}  →  {candidate.TargetTag}";
        PackageText.Text = candidate.PackageKind == UpdatePackageKind.Delta
            ? $"Инкрементальное обновление · {FormatBytes(candidate.SelectedAsset.Size)}"
            : $"Полный Setup · {FormatBytes(candidate.SelectedAsset.Size)}";
        ReasonText.Text = candidate.Reason;
        LastResultText.Text = "Последний результат:\n" +
                              UpdateService.GetLastResultSummary();
    }

    public bool InstallRequested { get; private set; }

    private void TitleBar_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void InstallButton_OnClick(object sender, RoutedEventArgs e)
    {
        InstallRequested = true;
        DialogResult = true;
    }

    private void CancelButton_OnClick(object sender, RoutedEventArgs e)
        => DialogResult = false;

    private static string FormatBytes(long bytes)
    {
        if (bytes <= 0)
        {
            return "размер неизвестен";
        }

        return bytes >= 1024L * 1024L
            ? $"{bytes / (1024d * 1024d):0.0} МБ"
            : $"{bytes / 1024d:0.0} КБ";
    }
}
