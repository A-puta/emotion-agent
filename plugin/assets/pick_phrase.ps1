param(
  [double]$SilenceHours = 999,
  [string]$Foreground = 'other',
  [string]$Weather = '',
  [string]$Tag = '',
  [string]$Now = '',
  [switch]$Show
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$ErrorActionPreference = 'Stop'
$root = 'D:\DSH-资料\外部哨兵'
$libPath = Join-Path $root '日常话语库.json'
$usedPath = Join-Path $root 'phrase-usage.json'

$lib = Get-Content $libPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($Now -ne '') { $t = [datetime]::Parse($Now) } else { $t = Get-Date }
$today = $t.ToString('yyyy-MM-dd')
$hour = $t.Hour
if ($hour -lt 5) { $hour += 24 }          # 凌晨算前一天深夜
$weekend = ($t.DayOfWeek -eq 'Saturday' -or $t.DayOfWeek -eq 'Sunday')

$used = [pscustomobject]@{ date = $today; total = 0; byTag = @{}; recent = @(); lastAt = $null }
if (Test-Path $usedPath) {
  try {
    $j = Get-Content $usedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.date -eq $today) { $used = $j }
  } catch { }
}

function Num($v) { if ($null -eq $v) { 0 } else { [int]$v } }

$cands = @()
foreach ($l in $lib.lines) {
  $c = $l.cond
  if ($Tag -ne '' -and $l.tag -ne $Tag) { continue }

  if ($c.hour) {
    $h = $c.hour
    if ($h.Count -eq 2) { if ($hour -lt (Num $h[0]) -or $hour -gt (Num $h[1])) { continue } }
    else {
      $ok = $false
      foreach ($start in $h) { if ($hour -ge (Num $start) -and $hour -lt ((Num $start) + 1)) { $ok = $true } }
      if (-not $ok) { continue }
    }
  }
  if ($c.weekday -eq 'weekend' -and -not $weekend) { continue }
  if ($c.foreground -and $Foreground -ne $c.foreground) { continue }
  if ($c.foreground_not -and $Foreground -eq $c.foreground_not) { continue }
  if ($c.silence_min -and $SilenceHours -lt (Num $c.silence_min)) { continue }
  if ($c.silence_max -and $SilenceHours -gt (Num $c.silence_max)) { continue }
  if ($c.weather) {
    $map = @{ rain = '雨'; sun = '晴'; overcast = '阴'; windy = '风' }
    $need = $map[[string]$c.weather]
    if ($Weather -eq '' -or $Weather -notlike "*$need*") { continue }
  }
  if ($c.today_msgs_min) { continue }   # 需要消息计数，暂不启用
  if ($used.recent -contains $l.text) { continue }

  $usedTag = 0
  if ($used.byTag -and $used.byTag.PSObject.Properties.Name -contains $l.tag) { $usedTag = [int]$used.byTag.($l.tag) }
  if ($c.daily_max -and $usedTag -ge (Num $c.daily_max)) { continue }

  $cands += [pscustomobject]@{ tag = $l.tag; text = $l.text }
}

if ($cands.Count -eq 0) {
  if ($Show) { Write-Output 'pick: 没有满足条件的句子' }
  exit 0
}

$pick = $cands | Get-Random
$text = $pick.text
if ($text -match '\{天气\}') {
  $w = if ($Weather -ne '') { $Weather } else { '晴' }
  $text = $text.Replace('{天气}', $w)
}
if ($text -match '\{时间\}') { $text = $text.Replace('{时间}', $t.ToString('HH:mm')) }

if ($Show) {
  Write-Output ("pick: [{0}] {1}" -f $pick.tag, $text)
  exit 0
}

# 记账
$used.total = (Num $used.total) + 1
$used.lastAt = $t.ToString('yyyy-MM-ddTHH:mm:ss')
$used.date = $today
if (-not $used.byTag) { $used.byTag = [pscustomobject]@{} }
$cur = 0
if ($used.byTag.PSObject.Properties.Name -contains $pick.tag) { $cur = [int]$used.byTag.($pick.tag) }
$used.byTag | Add-Member -NotePropertyName $pick.tag -NotePropertyValue ($cur + 1) -Force
$recent = @($used.recent) + $text
if ($recent.Count -gt 12) { $recent = $recent[($recent.Count - 12)..($recent.Count - 1)] }
$used.recent = $recent
$used | ConvertTo-Json -Depth 5 | Set-Content $usedPath -Encoding UTF8

Write-Output $text
