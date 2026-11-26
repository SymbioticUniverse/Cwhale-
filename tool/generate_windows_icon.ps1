param(
  [string]$OutputPath = (Join-Path $PSScriptRoot '..\windows\runner\resources\app_icon.ico')
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Convert-LogoPoint([double]$x, [double]$y, [int]$size) {
  return [System.Drawing.PointF]::new(
    [single]($x * $size / 100.0),
    [single]($y * $size / 100.0)
  )
}

function New-LogoPng([int]$size) {
  $bitmap = [System.Drawing.Bitmap]::new(
    $size,
    $size,
    [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
  )
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $body = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $belly = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $waves = [System.Drawing.Drawing2D.GraphicsPath]::new()

  try {
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::White)

    $body.StartFigure()
    $body.AddBezier((Convert-LogoPoint 13 48 $size), (Convert-LogoPoint 25 40 $size), (Convert-LogoPoint 38 35 $size), (Convert-LogoPoint 53 35 $size))
    $body.AddBezier((Convert-LogoPoint 53 35 $size), (Convert-LogoPoint 68 35 $size), (Convert-LogoPoint 77 29 $size), (Convert-LogoPoint 87 27 $size))
    $body.AddBezier((Convert-LogoPoint 87 27 $size), (Convert-LogoPoint 81 34 $size), (Convert-LogoPoint 77 40 $size), (Convert-LogoPoint 73 47 $size))
    $body.AddBezier((Convert-LogoPoint 73 47 $size), (Convert-LogoPoint 64 60 $size), (Convert-LogoPoint 52 64 $size), (Convert-LogoPoint 39 61 $size))
    $body.AddBezier((Convert-LogoPoint 39 61 $size), (Convert-LogoPoint 28 58 $size), (Convert-LogoPoint 20 52 $size), (Convert-LogoPoint 13 48 $size))
    $body.StartFigure()
    $body.AddBezier((Convert-LogoPoint 13 48 $size), (Convert-LogoPoint 27 46 $size), (Convert-LogoPoint 38 48 $size), (Convert-LogoPoint 48 51 $size))
    $body.AddBezier((Convert-LogoPoint 48 51 $size), (Convert-LogoPoint 60 54 $size), (Convert-LogoPoint 70 51 $size), (Convert-LogoPoint 81 45 $size))

    $belly.StartFigure()
    $belly.AddBezier((Convert-LogoPoint 22 53 $size), (Convert-LogoPoint 39 60 $size), (Convert-LogoPoint 57 60 $size), (Convert-LogoPoint 78 49 $size))
    $belly.StartFigure()
    $belly.AddBezier((Convert-LogoPoint 28 58 $size), (Convert-LogoPoint 45 64 $size), (Convert-LogoPoint 60 61 $size), (Convert-LogoPoint 74 53 $size))

    $waves.StartFigure()
    $waves.AddBezier((Convert-LogoPoint 15 74 $size), (Convert-LogoPoint 25 79 $size), (Convert-LogoPoint 33 78 $size), (Convert-LogoPoint 41 74 $size))
    $waves.AddBezier((Convert-LogoPoint 41 74 $size), (Convert-LogoPoint 50 70 $size), (Convert-LogoPoint 57 70 $size), (Convert-LogoPoint 66 74 $size))
    $waves.AddBezier((Convert-LogoPoint 66 74 $size), (Convert-LogoPoint 74 78 $size), (Convert-LogoPoint 81 78 $size), (Convert-LogoPoint 86 75 $size))

    $gradientBounds = [System.Drawing.RectangleF]::new(0, 0, $size, $size)
    $gradient = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
      $gradientBounds,
      [System.Drawing.Color]::FromArgb(255, 23, 105, 255),
      [System.Drawing.Color]::FromArgb(255, 8, 191, 214),
      [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal
    )
    $outlineWidth = [single][Math]::Max(1.5, $size * 0.055)
    $detailWidth = [single][Math]::Max(1.0, $size * 0.035)
    $outline = [System.Drawing.Pen]::new($gradient, $outlineWidth)
    $detail = [System.Drawing.Pen]::new($gradient, $detailWidth)
    foreach ($pen in @($outline, $detail)) {
      $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
      $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
      $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    }
    try {
      $graphics.DrawPath($outline, $body)
      $graphics.DrawPath($detail, $belly)
      $graphics.DrawPath($detail, $waves)
      $graphics.DrawLine(
        $detail,
        (Convert-LogoPoint 15 82 $size),
        (Convert-LogoPoint 86 82 $size)
      )
      $stream = [System.IO.MemoryStream]::new()
      try {
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return ,$stream.ToArray()
      } finally {
        $stream.Dispose()
      }
    } finally {
      $detail.Dispose()
      $outline.Dispose()
      $gradient.Dispose()
    }
  } finally {
    $waves.Dispose()
    $belly.Dispose()
    $body.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
  }
}

$sizes = @(16, 24, 32, 48, 64, 128, 256)
$images = foreach ($size in $sizes) {
  [pscustomobject]@{ Size = $size; Bytes = (New-LogoPng $size) }
}

$directory = Split-Path -Parent $OutputPath
New-Item -ItemType Directory -Force -Path $directory | Out-Null
$stream = [System.IO.File]::Open(
  $OutputPath,
  [System.IO.FileMode]::Create,
  [System.IO.FileAccess]::Write,
  [System.IO.FileShare]::None
)
$writer = [System.IO.BinaryWriter]::new($stream)
try {
  $writer.Write([uint16]0)
  $writer.Write([uint16]1)
  $writer.Write([uint16]$images.Count)
  $offset = 6 + (16 * $images.Count)
  foreach ($image in $images) {
    $dimension = if ($image.Size -eq 256) { [byte]0 } else { [byte]$image.Size }
    $writer.Write($dimension)
    $writer.Write($dimension)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$image.Bytes.Length)
    $writer.Write([uint32]$offset)
    $offset += $image.Bytes.Length
  }
  foreach ($image in $images) {
    $writer.Write([byte[]]$image.Bytes)
  }
} finally {
  $writer.Dispose()
  $stream.Dispose()
}

Write-Output "Created Cwhale multi-size Windows icon: $OutputPath"
