# Generates the glyph atlases in app/internal/gfx/fonts: one <name>.a8 (raw 8-bit
# coverage, 95 cells of cellW x cellH, ASCII 32..126) plus <name>.json with the
# cell size and per-glyph advances. Text is drawn with a 9/8 horizontal stretch
# so letters have their true shape on the 8/9 pixel of a 720x480 CRT frame;
# sizes and weights are selected for legibility on interlaced displays.
#   powershell -File app\tools\genatlas.ps1
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot "..\internal\gfx\fonts"
$SX = 1.125
function Gen($name, $family, $px, $style) {
  $font = New-Object System.Drawing.Font($family, [float]$px, $style, [System.Drawing.GraphicsUnit]::Pixel)
  $cellW = [int][Math]::Ceiling($px * 1.3 * $SX) + 2
  $cellH = [int][Math]::Ceiling($px * 1.25) + 2
  $bmp = New-Object System.Drawing.Bitmap($cellW, $cellH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
  $fmt = New-Object System.Drawing.StringFormat([System.Drawing.StringFormat]::GenericTypographic)
  $fmt.FormatFlags = $fmt.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces
  $data = New-Object byte[] (95 * $cellW * $cellH)
  $adv = @()
  for ($c = 32; $c -le 126; $c++) {
    $g.ResetTransform(); $g.Clear([System.Drawing.Color]::Black)
    $g.ScaleTransform([float]$SX, 1.0)
    $str = [string][char]$c
    $g.DrawString($str, $font, [System.Drawing.Brushes]::White, [float](1 / $SX), [float]0, $fmt)
    $w = [Math]::Round($g.MeasureString($str, $font, 1000, $fmt).Width * $SX)
    if ($w -lt 3) { $w = [Math]::Round($px * 0.28 * $SX) }
    $adv += [int]$w
    $base = ($c - 32) * $cellW * $cellH
    for ($y = 0; $y -lt $cellH; $y++) { for ($x = 0; $x -lt $cellW; $x++) { $data[$base + $y * $cellW + $x] = $bmp.GetPixel($x, $y).R } }
  }
  [System.IO.File]::WriteAllBytes((Join-Path $out "$name.a8"), $data)
  $meta = @{ family = $family; px = $px; cellW = $cellW; cellH = $cellH; ox = 1; adv = $adv } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText((Join-Path $out "$name.json"), $meta)
  "$name : cell ${cellW}x${cellH}"
  $g.Dispose(); $bmp.Dispose()
}
$R = [System.Drawing.FontStyle]::Regular; $B = [System.Drawing.FontStyle]::Bold
Gen "reg16"  "Roboto" 16 $R
Gen "med16"  "Roboto Medium" 16 $R
Gen "reg18"  "Roboto" 18 $R
Gen "med18"  "Roboto Medium" 18 $R
Gen "bold18" "Roboto" 18 $B
Gen "med22"  "Roboto Medium" 22 $R
Gen "bold22" "Roboto" 22 $B
Gen "bold28" "Roboto" 28 $B
$BI = [System.Drawing.FontStyle]::Bold -bor [System.Drawing.FontStyle]::Italic
# nothing in this app loads blackit26; supporter builds do (docs/SUPPORTER_BUILDS.md)
Gen "blackit26" "Roboto Black" 26 $BI
Gen "condit24" "Roboto Condensed" 24 $BI # the beta access screen's title
