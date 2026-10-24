# collector.ps1 - QQ chat-list scanner / chat capturer for later review by the assistant.
# ASCII-only body (PS 5.1 reads .ps1 as ANSI). Output goes to an ASCII folder: D:\DSH-资料\inbox
#
# Usage:
#   collector.ps1 -Scan            -> idle gate + focus QQ + capture the chat-list strip + detect red unread badges
#   collector.ps1 -Scan -Force     -> same but ignore the idle gate
#   collector.ps1 -Open 1          -> open the 1st detected unread chat and capture its message area
#   collector.ps1 -Status          -> show inbox contents / last scan
# Notes: it never types, never sends, never reads message text (only pixels).

param(
  [switch]$Scan, [switch]$Status, [switch]$Force,
  [int]$Open = -1,
  [int]$RowY = -1,
  [int]$IdleSeconds = 0,
  [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# Paths come from config (UTF-8) or from the script's own folder -- never from a Chinese literal here,
# because PS 5.1 reads this .ps1 as ANSI and would mangle it.
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $root 'collector.config.json'
if (Test-Path -LiteralPath $cfgPath) {
  try {
    $c = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($c.outDir) { $OutDir = [string]$c.outDir }
    if ($c.idleSeconds -and $IdleSeconds -eq 0) { $IdleSeconds = [int]$c.idleSeconds }
  } catch { }
}
if (-not $OutDir) { $OutDir = Join-Path $root 'inbox' }
if ($IdleSeconds -le 0) { $IdleSeconds = 120 }

Add-Type @"
using System;using System.Runtime.InteropServices;
public class Col {
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool alt);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, int data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
# Coordinates and screenshots must be in true physical pixels, otherwise measured row offsets do not
# match where the click lands.
try { [Col]::SetProcessDPIAware() | Out-Null } catch { }

function Get-IdleSeconds {
  $li = New-Object Col+LASTINPUTINFO
  $li.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($li)
  [Col]::GetLastInputInfo([ref]$li) | Out-Null
  $ticks = [Environment]::TickCount
  $d = $ticks - [int]$li.dwTime
  if ($d -lt 0) { $d += [uint32]::MaxValue }
  return [int]($d / 1000)
}
function Get-Qq {
  return (Get-Process -Name QQ -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1)
}
function Get-Rect($h) {
  $r = New-Object Col+RECT
  [Col]::GetWindowRect($h, [ref]$r) | Out-Null
  return $r
}
function Focus-Qq($h, [int]$pid2) {
  $fpid = 0
  [Col]::GetWindowThreadProcessId([Col]::GetForegroundWindow(), [ref]$fpid) | Out-Null
  for ($i = 1; $i -le 3; $i++) {
    if ($fpid -eq $pid2) { return $true }
    [Col]::ShowWindow($h, 9) | Out-Null
    [Col]::SwitchToThisWindow($h, $true) | Out-Null
    Start-Sleep -Milliseconds 350
    [Col]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x43) | Out-Null
    Start-Sleep -Milliseconds 250
    [Col]::SetForegroundWindow($h) | Out-Null
    Start-Sleep -Milliseconds 250
    [Col]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, 0x43) | Out-Null
    Start-Sleep -Milliseconds 250
    $fpid = 0
    [Col]::GetWindowThreadProcessId([Col]::GetForegroundWindow(), [ref]$fpid) | Out-Null
  }
  return ($fpid -eq $pid2)
}
function Save-Crop([int]$x, [int]$y, [int]$w, [int]$h2, [string]$path) {
  $b = New-Object System.Drawing.Bitmap($w, $h2)
  $g = [System.Drawing.Graphics]::FromImage($b)
  $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size($w, $h2)))
  $g.Dispose()
  $b.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $b.Dispose()
}
# Red badge rows are only a HINT: QQ also shows GRAY count pills (muted chats) which this cannot see.
# Restricted to the right-hand badge column so avatar colours / the sidebar dot do not produce false hits.
function Find-RedBands([string]$path, [int]$xFrom, [int]$xTo, [int]$minPixelsPerRow = 6) {
  $bmp = [System.Drawing.Bitmap]::FromFile($path)
  $w = $bmp.Width; $h = $bmp.Height
  if ($xTo -gt $w) { $xTo = $w }
  $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
  $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $stride = $data.Stride
  $bytes = New-Object byte[] ($stride * $h)
  [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
  $bmp.UnlockBits($data)
  $bmp.Dispose()
  $hitRows = @()
  for ($y = 0; $y -lt $h; $y++) {
    $cnt = 0
    $base = $y * $stride
    for ($x = $xFrom; $x -lt $xTo; $x++) {
      $i = $base + $x * 4
      $bl = $bytes[$i]; $gr = $bytes[$i + 1]; $rd = $bytes[$i + 2]
      if ($rd -gt 185 -and $gr -lt 105 -and $bl -lt 105) { $cnt++ }
    }
    if ($cnt -ge $minPixelsPerRow) { $hitRows += $y }
  }
  $bands = @()
  $prev = -99; $start = -1
  foreach ($y in $hitRows) {
    if ($start -lt 0) { $start = $y }
    elseif ($y - $prev -gt 3) { $bands += [pscustomobject]@{ top = $start; bottom = $prev; center = [int](($start + $prev) / 2) }; $start = $y }
    $prev = $y
  }
  if ($start -ge 0) { $bands += [pscustomobject]@{ top = $start; bottom = $prev; center = [int](($start + $prev) / 2) } }
  return $bands
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$manifestPath = Join-Path $OutDir 'manifest.json'
$logPath = Join-Path $OutDir 'collector.log'
function CLog([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { }
  Write-Host $line
}

if ($Status) {
  $m = $null
  if (Test-Path -LiteralPath $manifestPath) { try { $m = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { } }
  "inbox : $OutDir"
  "files : " + ((Get-ChildItem -LiteralPath $OutDir -File -Filter *.png -ErrorAction SilentlyContinue | Measure-Object).Count)
  if ($m -and $m.lastScan) { "last  : $($m.lastScan)  badges=$(@($m.badges).Count)" } else { "last  : none" }
  "idle  : $(Get-IdleSeconds)s  (gate $IdleSeconds s)"
  exit 0
}

$p = Get-Qq
if (-not $p) { "QQ not running"; exit 1 }
$h = $p.MainWindowHandle

if ($Open -ge 0 -or $RowY -ge 0) {
  if (-not (Focus-Qq $h $p.Id)) { "QQ not foreground -> abort"; exit 1 }
  $m = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
  $listX = [int]$m.listX; $listY = [int]$m.listY
  $r = Get-Rect $h
  if ($RowY -ge 0) {
    $yOff = $RowY; $which = "rowY$RowY"
  } else {
    $bands = @($m.bands)
    if ($Open -ge $bands.Count) { "no band #$Open (have $($bands.Count))"; exit 1 }
    $yOff = [int]$bands[$Open].center; $which = "#$Open"
  }
  [Col]::SetCursorPos(($r.Left + $listX + 150), ($r.Top + $listY + $yOff)) | Out-Null
  Start-Sleep -Milliseconds 250
  [Col]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
  [Col]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 1900
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $headPath = Join-Path $OutDir ("head_$which`_$stamp.png")
  Save-Crop ($r.Left + 340) ($r.Top + 55) 1100 90 $headPath
  $chatPath = Join-Path $OutDir ("chat_$which`_$stamp.png")
  Save-Crop ($r.Left + 340) ($r.Top + 90) 1500 950 $chatPath
  "opened $which (listY+$yOff)"
  "header -> $headPath"
  "chat   -> $chatPath"
  exit 0
}

# ---- default: scan ----
$idle = Get-IdleSeconds
if (-not $Force -and $idle -lt $IdleSeconds) { "skip: user active (idle ${idle}s < $IdleSeconds s)"; exit 0 }
if (-not (Focus-Qq $h $p.Id)) { "QQ not foreground -> abort (no capture)"; exit 1 }
Start-Sleep -Milliseconds 400
$r = Get-Rect $h
$listX = 60; $listY = 125; $listW = 410; $listH = 1000
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$listPath = Join-Path $OutDir ("list_$stamp.png")
Save-Crop ($r.Left + $listX) ($r.Top + $listY) $listW $listH $listPath
$bands = Find-RedBands $listPath 320 410
$m = [pscustomobject]@{
  lastScan = (Get-Date).ToString('s')
  listX = $listX; listY = $listY; listW = $listW; listH = $listH
  windowRect = @{ left = $r.Left; top = $r.Top; right = $r.Right; bottom = $r.Bottom }
  listFile = (Split-Path -Leaf $listPath)
  bands = $bands
}
[IO.File]::WriteAllText($manifestPath, ($m | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
CLog ("scan ok: " + $listPath)
$bandTxt = 'none'
if (@($bands).Count -gt 0) { $bandTxt = (($bands | ForEach-Object { $_.center }) -join ',') }
CLog ("unread badge bands (red hint only): {0} -> {1}" -f @($bands).Count, $bandTxt)
