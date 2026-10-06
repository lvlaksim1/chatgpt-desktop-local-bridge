param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$code = @"
using System;
using System.Runtime.InteropServices;
public static class LocalBridgeIconNative {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@
Add-Type -TypeDefinition $code -ErrorAction SilentlyContinue

$dir = Split-Path -Parent $OutputPath
if ($dir) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

$size = 256
$bitmap = New-Object System.Drawing.Bitmap $size, $size
$graphics = [System.Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

function New-RoundedPath(
    [float]$X,
    [float]$Y,
    [float]$W,
    [float]$H,
    [float]$R
) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

try {
    $graphics.Clear([System.Drawing.Color]::FromArgb(7, 14, 28))

    $background = New-RoundedPath 12 12 232 232 46
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 20, 20),
        (New-Object System.Drawing.Point 230, 235),
        [System.Drawing.Color]::FromArgb(16, 52, 99),
        [System.Drawing.Color]::FromArgb(3, 15, 33))
    $graphics.FillPath($bgBrush, $background)

    $borderPen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(70, 63, 169, 255), 3)
    $graphics.DrawPath($borderPen, $background)

    # Chat bubble.
    $bubble = New-RoundedPath 30 88 80 66 19
    $bubbleBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 30, 88),
        (New-Object System.Drawing.Point 110, 154),
        [System.Drawing.Color]::FromArgb(89, 226, 255),
        [System.Drawing.Color]::FromArgb(0, 92, 238))
    $graphics.FillPath($bubbleBrush, $bubble)

    $tail = New-Object System.Drawing.Drawing2D.GraphicsPath
    $tail.AddPolygon(@(
        (New-Object System.Drawing.PointF 43, 145),
        (New-Object System.Drawing.PointF 38, 171),
        (New-Object System.Drawing.PointF 62, 151)))
    $graphics.FillPath($bubbleBrush, $tail)

    $white = New-Object System.Drawing.SolidBrush(
        [System.Drawing.Color]::FromArgb(236, 247, 255))
    foreach ($x in @(52, 70, 88)) {
        $graphics.FillEllipse($white, $x, 115, 10, 10)
    }

    # Bridge.
    $cyan = [System.Drawing.Color]::FromArgb(72, 240, 255)
    $bridgePen = New-Object System.Drawing.Pen($cyan, 7)
    $bridgePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $bridgePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawBezier(
        $bridgePen,
        (New-Object System.Drawing.Point 101, 140),
        (New-Object System.Drawing.Point 124, 114),
        (New-Object System.Drawing.Point 153, 114),
        (New-Object System.Drawing.Point 176, 140))

    $railPen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(165, 109, 255, 255), 3)
    $graphics.DrawBezier(
        $railPen,
        (New-Object System.Drawing.Point 102, 120),
        (New-Object System.Drawing.Point 126, 151),
        (New-Object System.Drawing.Point 151, 151),
        (New-Object System.Drawing.Point 175, 120))

    foreach ($x in @(108, 125, 142, 159, 176)) {
        $graphics.DrawLine(
            $railPen,
            (New-Object System.Drawing.Point $x, 126),
            (New-Object System.Drawing.Point $x, 142))
    }

    # Monitor.
    $monitorOuter = New-RoundedPath 164 79 70 70 8
    $silver = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 164, 79),
        (New-Object System.Drawing.Point 234, 149),
        [System.Drawing.Color]::FromArgb(233, 244, 255),
        [System.Drawing.Color]::FromArgb(120, 153, 196))
    $graphics.FillPath($silver, $monitorOuter)

    $screenBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (New-Object System.Drawing.Point 171, 88),
        (New-Object System.Drawing.Point 227, 139),
        [System.Drawing.Color]::FromArgb(0, 176, 255),
        [System.Drawing.Color]::FromArgb(0, 47, 153))
    $graphics.FillRectangle($screenBrush, 172, 88, 54, 50)

    $standPen = New-Object System.Drawing.Pen(
        [System.Drawing.Color]::FromArgb(190, 216, 242), 8)
    $standPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $standPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $graphics.DrawLine(
        $standPen,
        (New-Object System.Drawing.Point 199, 149),
        (New-Object System.Drawing.Point 199, 173))
    $graphics.DrawLine(
        $standPen,
        (New-Object System.Drawing.Point 180, 176),
        (New-Object System.Drawing.Point 218, 176))

    $handle = $bitmap.GetHicon()
    try {
        $icon = [System.Drawing.Icon]::FromHandle($handle)
        $stream = [System.IO.File]::Open(
            $OutputPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        try {
            $icon.Save($stream)
        }
        finally {
            $stream.Dispose()
            $icon.Dispose()
        }
    }
    finally {
        [LocalBridgeIconNative]::DestroyIcon($handle) | Out-Null
    }
}
finally {
    foreach ($item in @(
        $bridgePen, $railPen, $borderPen, $bgBrush,
        $bubbleBrush, $white, $silver, $screenBrush,
        $standPen, $tail, $bubble, $background
    )) {
        if ($null -ne $item) {
            try { $item.Dispose() } catch {}
        }
    }

    $graphics.Dispose()
    $bitmap.Dispose()
}
