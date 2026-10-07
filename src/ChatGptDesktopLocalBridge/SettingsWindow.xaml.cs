using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace ChatGptDesktopLocalBridge;

public partial class SettingsWindow
{
    private bool _ready;

    public SettingsWindow(AppSettings settings)
    {
        InitializeComponent();

        AutoBridgeCheckBox.IsChecked = settings.AutoInitializeBridge;
        SetColor(ThemePalette.IsValidHex(settings.ThemeColor)
            ? settings.ThemeColor
            : "#202124");

        UpdateHistoryText.Text = UpdateService.GetRecentHistoryText();
        _ready = true;
        UpdatePreview();
    }

    public string SelectedThemeColor { get; private set; } = "#202124";
    public bool SelectedAutoInitializeBridge { get; private set; } = true;

    private void TitleBar_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.LeftButton == MouseButtonState.Pressed)
        {
            DragMove();
        }
    }

    private void PresetButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string color })
        {
            SetColor(color);
            UpdatePreview();
        }
    }

    private void ColorSlider_OnValueChanged(
        object sender,
        RoutedPropertyChangedEventArgs<double> e)
    {
        if (_ready)
        {
            UpdatePreview();
        }
    }

    private void UpdatePreview()
    {
        var r = (byte)Math.Round(RedSlider.Value);
        var g = (byte)Math.Round(GreenSlider.Value);
        var b = (byte)Math.Round(BlueSlider.Value);

        RedValueText.Text = r.ToString();
        GreenValueText.Text = g.ToString();
        BlueValueText.Text = b.ToString();

        var color = Color.FromRgb(r, g, b);
        ColorPreview.Background = new SolidColorBrush(color);
        ColorHexText.Text = $"#{r:X2}{g:X2}{b:X2}";
    }

    private void SetColor(string value)
    {
        var color = ThemePalette.Parse(value);
        RedSlider.Value = color.R;
        GreenSlider.Value = color.G;
        BlueSlider.Value = color.B;
    }

    private void SaveButton_OnClick(object sender, RoutedEventArgs e)
    {
        SelectedThemeColor = ColorHexText.Text;
        SelectedAutoInitializeBridge = AutoBridgeCheckBox.IsChecked == true;
        DialogResult = true;
    }

    private void CancelButton_OnClick(object sender, RoutedEventArgs e)
        => DialogResult = false;
}
