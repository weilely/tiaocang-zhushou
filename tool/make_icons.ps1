# 重新生成安卓启动图标（legacy + 自适应前景），源图是一张方形的 LOGO 图。
#
# 用法：
#   pwsh -File tool/make_icons.ps1 -Source "E:\DSH\pic\微信图片_20260916143726_12_23.png"
#
# 做法（和之前手工生成时一致）：
#   1. 采样四角底色 → 写回 res/values/ic_launcher_background.xml
#   2. 用容差找内容的包围盒（LOGO 四周有柔和阴影，容差把阴影排除在内容之外）
#   3. legacy ic_launcher.png：内容宽 = 画布 77%，居中，铺底色
#   4. 自适应 ic_launcher_foreground.png：内容宽 = 画布 60%（落在 66dp 安全圈内），居中，铺底色
#   5. 全部双三次重采样

param(
  [string]$Source = 'E:\DSH\pic\微信图片_20260916143726_12_23.png',
  [int]$Tolerance = 20,
  [double]$LegacyRatio = 0.77,
  [double]$AdaptiveRatio = 0.60,
  [switch]$FullBleed = $true
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$resDir = Join-Path $PSScriptRoot '..\android\app\src\main\res'
$resDir = (Resolve-Path $resDir).Path
if (-not (Test-Path $Source)) { throw "源图不存在：$Source" }

# 每档：目录名, legacy 边长, 自适应前景边长(108dp 的 2.25 倍)
$densities = @(
  @{ dir = 'mipmap-mdpi';    legacy = 48;  fg = 108 },
  @{ dir = 'mipmap-hdpi';    legacy = 72;  fg = 162 },
  @{ dir = 'mipmap-xhdpi';   legacy = 96;  fg = 216 },
  @{ dir = 'mipmap-xxhdpi';  legacy = 144; fg = 324 },
  @{ dir = 'mipmap-xxxhdpi'; legacy = 192; fg = 432 }
)

# ---------- 读图（转成 24bpp，省得纠结 alpha） ----------
$srcImg = [System.Drawing.Image]::FromFile($Source)
$bmp = New-Object System.Drawing.Bitmap($srcImg.Width, $srcImg.Height, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.DrawImage($srcImg, [System.Drawing.Rectangle]::new(0, 0, $srcImg.Width, $srcImg.Height))
$g.Dispose()
$srcImg.Dispose()

$w = $bmp.Width
$h = $bmp.Height

# ---------- 底色：四角平均 ----------
$rect = [System.Drawing.Rectangle]::new(0, 0, $w, $h)
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$stride = $data.Stride
$bytes = New-Object byte[] ($stride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$bmp.UnlockBits($data)

function Get-Pixel([int]$x, [int]$y) {
  $i = $y * $stride + $x * 3
  return @($bytes[$i + 2], $bytes[$i + 1], $bytes[$i])   # BGR → R,G,B
}

$corners = @(
  (Get-Pixel 2 2), (Get-Pixel ($w - 3) 2), (Get-Pixel 2 ($h - 3)), (Get-Pixel ($w - 3) ($h - 3))
)
$bgR = [int](($corners | ForEach-Object { $_[0] } | Measure-Object -Average).Average)
$bgG = [int](($corners | ForEach-Object { $_[1] } | Measure-Object -Average).Average)
$bgB = [int](($corners | ForEach-Object { $_[2] } | Measure-Object -Average).Average)
$bgHex = '#{0:X2}{1:X2}{2:X2}' -f $bgR, $bgG, $bgB
Write-Host "底色采样：$bgHex"

# ---------- 内容包围盒（步进 2px 够准） ----------
$minX = $w; $minY = $h; $maxX = -1; $maxY = -1
for ($y = 0; $y -lt $h; $y += 2) {
  for ($x = 0; $x -lt $w; $x += 2) {
    $i = $y * $stride + $x * 3
    $b = $bytes[$i]; $gg = $bytes[$i + 1]; $r = $bytes[$i + 2]
    $d = [Math]::Max([Math]::Abs($r - $bgR), [Math]::Max([Math]::Abs($gg - $bgG), [Math]::Abs($b - $bgB)))
    if ($d -gt $Tolerance) {
      if ($x -lt $minX) { $minX = $x }
      if ($x -gt $maxX) { $maxX = $x }
      if ($y -lt $minY) { $minY = $y }
      if ($y -gt $maxY) { $maxY = $y }
    }
  }
}
if ($maxX -lt 0) { throw '没找到内容：容差可能太大' }
$srcRect = if ($FullBleed) { [System.Drawing.Rectangle]::new(0, 0, $w, $h) } else { [System.Drawing.Rectangle]::new($minX, $minY, ($maxX - $minX + 1), ($maxY - $minY + 1)) }
Write-Host "内容包围盒：$($srcRect.Width)x$($srcRect.Height) @ ($minX,$minY)"

# ---------- 出图 ----------
$bgColor = [System.Drawing.Color]::FromArgb(255, $bgR, $bgG, $bgB)

function Write-Icon([string]$path, [int]$canvas, [double]$ratio) {
  $bmpOut = New-Object System.Drawing.Bitmap($canvas, $canvas, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
  $gOut = [System.Drawing.Graphics]::FromImage($bmpOut)
  $gOut.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $gOut.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $gOut.Clear($bgColor)

  $target = $canvas * $ratio
  $scale = $target / [Math]::Max($srcRect.Width, $srcRect.Height)
  $dw = [int][Math]::Round($srcRect.Width * $scale)
  $dh = [int][Math]::Round($srcRect.Height * $scale)
  $dx = [int][Math]::Round(($canvas - $dw) / 2.0)
  $dy = [int][Math]::Round(($canvas - $dh) / 2.0)

  $gOut.DrawImage($bmp, [System.Drawing.Rectangle]::new($dx, $dy, $dw, $dh), $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
  $gOut.Dispose()
  $bmpOut.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmpOut.Dispose()
}

foreach ($d in $densities) {
  $dir = Join-Path $resDir $d.dir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
  Write-Icon (Join-Path $dir 'ic_launcher.png') $d.legacy $LegacyRatio
  Write-Icon (Join-Path $dir 'ic_launcher_foreground.png') $d.fg $AdaptiveRatio
  Write-Host "  $($d.dir): legacy $($d.legacy) / fg $($d.fg)"
}

$bmp.Dispose()

# ---------- 底色写回 values ----------
$colorXml = Join-Path $resDir 'values\ic_launcher_background.xml'
$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">$bgHex</color>
</resources>
"@
[System.IO.File]::WriteAllText($colorXml, $xml, [System.Text.UTF8Encoding]::new($false))
Write-Host "已写入 $colorXml"
Write-Host '完成。'
