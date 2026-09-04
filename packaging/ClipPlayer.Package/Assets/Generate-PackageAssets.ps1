param(
    [string]$OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function New-ClipPlayerIcon {
    param(
        [int]$Size,
        [string]$Path
    )

    $bitmap = [Drawing.Bitmap]::new($Size, $Size)
    $bitmap.SetResolution(96, 96)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::FromArgb(18, 24, 38))

    $margin = [Math]::Max(1, [int]($Size * 0.08))
    $radius = [Math]::Max(2, [int]($Size * 0.18))
    $background = [Drawing.Rectangle]::new($margin, $margin, $Size - 2 * $margin, $Size - 2 * $margin)
    $pathShape = [Drawing.Drawing2D.GraphicsPath]::new()
    $pathShape.AddArc($background.X, $background.Y, $radius, $radius, 180, 90)
    $pathShape.AddArc($background.Right - $radius, $background.Y, $radius, $radius, 270, 90)
    $pathShape.AddArc($background.Right - $radius, $background.Bottom - $radius, $radius, $radius, 0, 90)
    $pathShape.AddArc($background.X, $background.Bottom - $radius, $radius, $radius, 90, 90)
    $pathShape.CloseFigure()
    $graphics.FillPath([Drawing.Brushes]::MidnightBlue, $pathShape)

    $wavePen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(79, 209, 197), [Math]::Max(1, [int]($Size * 0.09)))
    $wavePen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $wavePen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $points = [Drawing.PointF[]]@(
        [Drawing.PointF]::new($Size * 0.22, $Size * 0.56),
        [Drawing.PointF]::new($Size * 0.34, $Size * 0.56),
        [Drawing.PointF]::new($Size * 0.40, $Size * 0.34),
        [Drawing.PointF]::new($Size * 0.49, $Size * 0.74),
        [Drawing.PointF]::new($Size * 0.59, $Size * 0.28),
        [Drawing.PointF]::new($Size * 0.68, $Size * 0.62),
        [Drawing.PointF]::new($Size * 0.78, $Size * 0.62)
    )
    $graphics.DrawLines($wavePen, $points)

    $graphics.Dispose()
    $pathShape.Dispose()
    $wavePen.Dispose()
    $bitmap.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

$sizes = @{
    'StoreLogo' = 50
    'Square44x44Logo' = 44
    'Square150x150Logo' = 150
}
$scales = @{
    'scale-100' = 1.00
    'scale-125' = 1.25
    'scale-150' = 1.50
    'scale-200' = 2.00
    'scale-300' = 3.00
    'scale-400' = 4.00
}

foreach ($name in $sizes.Keys) {
    $baseSize = $sizes[$name]
    New-ClipPlayerIcon -Size $baseSize -Path (Join-Path $OutputDirectory "$name.png")
    foreach ($scale in $scales.Keys) {
        $size = [int][Math]::Round($baseSize * $scales[$scale])
        New-ClipPlayerIcon -Size $size -Path (Join-Path $OutputDirectory "$name.$scale.png")
    }
}
