using System.Globalization;
using System.Windows.Media;

namespace ChatGptDesktopLocalBridge;

public sealed record ThemePalette(
    string Base,
    string Surface,
    string SurfaceAlt,
    string SurfaceDeep,
    string TopBar,
    string Border,
    string Selected,
    string Button,
    string ButtonHover,
    string Text,
    string Muted)
{
    public bool IsLight => RelativeLuminance(Parse(Base)) > 0.55;

    public static ThemePalette FromBase(string? value)
    {
        var baseColor = TryParse(value, out var parsed)
            ? parsed
            : Color.FromRgb(0x20, 0x21, 0x24);

        var light = RelativeLuminance(baseColor) > 0.55;

        var surface = light
            ? Blend(baseColor, Colors.White, 0.10)
            : Blend(baseColor, Colors.White, 0.035);
        var surfaceAlt = light
            ? Blend(baseColor, Colors.Black, 0.035)
            : Blend(baseColor, Colors.White, 0.075);
        var deep = light
            ? Blend(baseColor, Colors.Black, 0.07)
            : Blend(baseColor, Colors.Black, 0.22);
        var top = light
            ? Blend(baseColor, Colors.Black, 0.16)
            : Blend(baseColor, Colors.Black, 0.12);
        var border = light
            ? Blend(baseColor, Colors.Black, 0.22)
            : Blend(baseColor, Colors.White, 0.14);
        var selected = light
            ? Blend(baseColor, Colors.Black, 0.09)
            : Blend(baseColor, Colors.White, 0.11);
        var button = light
            ? Blend(baseColor, Colors.Black, 0.13)
            : Blend(baseColor, Colors.White, 0.08);
        var buttonHover = light
            ? Blend(baseColor, Colors.Black, 0.20)
            : Blend(baseColor, Colors.White, 0.14);

        return new ThemePalette(
            ToHex(baseColor),
            ToHex(surface),
            ToHex(surfaceAlt),
            ToHex(deep),
            ToHex(top),
            ToHex(border),
            ToHex(selected),
            ToHex(button),
            ToHex(buttonHover),
            light ? "#17191C" : "#F2F3F5",
            light ? "#5E6268" : "#A5A9AF");
    }

    public static bool IsValidHex(string? value)
        => TryParse(value, out _);

    public static Color Parse(string value)
        => TryParse(value, out var color)
            ? color
            : Color.FromRgb(0x20, 0x21, 0x24);

    private static bool TryParse(string? value, out Color color)
    {
        color = default;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var text = value.Trim().TrimStart('#');
        if (text.Length != 6 ||
            !byte.TryParse(text[0..2], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var r) ||
            !byte.TryParse(text[2..4], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var g) ||
            !byte.TryParse(text[4..6], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var b))
        {
            return false;
        }

        color = Color.FromRgb(r, g, b);
        return true;
    }

    private static Color Blend(Color source, Color target, double amount)
    {
        amount = Math.Clamp(amount, 0, 1);
        byte Mix(byte a, byte b)
            => (byte)Math.Round(a + ((b - a) * amount));

        return Color.FromRgb(
            Mix(source.R, target.R),
            Mix(source.G, target.G),
            Mix(source.B, target.B));
    }

    private static double RelativeLuminance(Color color)
    {
        static double Channel(byte value)
        {
            var c = value / 255.0;
            return c <= 0.04045
                ? c / 12.92
                : Math.Pow((c + 0.055) / 1.055, 2.4);
        }

        return 0.2126 * Channel(color.R) +
               0.7152 * Channel(color.G) +
               0.0722 * Channel(color.B);
    }

    private static string ToHex(Color color)
        => $"#{color.R:X2}{color.G:X2}{color.B:X2}";
}
