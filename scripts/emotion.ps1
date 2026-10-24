param(
  [switch]$Show,
  [switch]$Tick,
  [switch]$Expire,
  [switch]$Reset,
  [string]$Set = '',
  [string]$Session = ''
)

$ErrorActionPreference = 'Stop'
$StateDir = 'D:\DSH-资料\结衣状态'
$File = Join-Path $StateDir 'emotion.json'
$Heavy = @('生气', '难过')
$Light = @('开心', '淘气', '害羞', '委屈')
$All = $Heavy + $Light
$SegGap = 10          # 分钟：间隔超过它就断段
$HeavyLife = 25       # 分钟
$LightLife = 10       # 分钟
$RecoverSpan = 30     # 分钟：每满这么久降一格疲惫
$Exclusive = @(@('开心', '难过'), @('生气', '委屈'))

function Now { Get-Date }
function Iso($d) { $d.ToString('yyyy-MM-ddTHH:mm:ss') }
function Parse($s) { if ([string]::IsNullOrWhiteSpace($s)) { $null } else { [datetime]::Parse($s) } }

function Load {
  if (Test-Path $File) {
    try {
      $j = Get-Content $File -Raw -Encoding UTF8 | ConvertFrom-Json
      return $j
    } catch { }
  }
  return [pscustomobject]@{
    sessionId = ''
    updatedAt = (Iso (Now))
    slots     = @()
    seg       = [pscustomobject]@{ startAt = $null; lastUserAt = $null; count = 0; lastA = 0 }
    fatigue   = 0
    fatigueAt = $null
    lock      = $false
  }
}

function Save($st) {
  $st.updatedAt = Iso (Now)
  $st.lock = ([int]$st.fatigue -ge 2)
  $json = $st | ConvertTo-Json -Depth 6
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($File, $json, $utf8)
}

function SlotList($st) {
  $out = @()
  foreach ($s in $st.slots) { $out += [pscustomobject]@{ label = $s.label; at = $s.at } }
  return $out
}

function IsHeavy($label) { return ($Heavy -contains $label) }
function LifeOf($label) { if (IsHeavy $label) { return $HeavyLife } else { return $LightLife } }

function ApplyExpire($st) {
  $now = Now
  $keep = @()
  $segEnd = $null
  $lastUser = Parse $st.seg.lastUserAt
  if ($lastUser -and (($now - $lastUser).TotalMinutes -gt $SegGap)) { $segEnd = $lastUser.AddMinutes($SegGap) }

  foreach ($s in $st.slots) {
    $at = Parse $s.at
    if (-not $at) { continue }
    if (-not $segEnd) { $keep += $s; continue }        # 段没结束，不计时
    $start = if ($at -gt $segEnd) { $at } else { $segEnd }
    $life = LifeOf $s.label
    if (($now - $start).TotalMinutes -lt $life) { $keep += $s }
  }
  $st.slots = $keep

  $fatigueAt = Parse $st.fatigueAt
  if ([int]$st.fatigue -gt 0 -and $fatigueAt) {
    $span = ($now - $fatigueAt).TotalMinutes
    if ($span -ge $RecoverSpan) {
      $steps = [math]::Floor($span / $RecoverSpan)
      $st.fatigue = [math]::Max(0, [int]$st.fatigue - [int]$steps)
      $st.fatigueAt = Iso ($fatigueAt.AddMinutes($steps * $RecoverSpan))
    }
  }
  return $st
}

function DoTick($st) {
  $now = Now
  $last = Parse $st.seg.lastUserAt
  if (-not $last -or (($now - $last).TotalMinutes -gt $SegGap)) {
    $st.seg.startAt = Iso $now
    $st.seg.count = 0
  }
  $st.seg.count = [int]$st.seg.count + 1
  $st.seg.lastUserAt = Iso $now

  $start = Parse $st.seg.startAt
  $R = [int]$st.seg.count
  if ($R -ge 2 -and $start) {
    $st.seg.lastA = [math]::Round((($now - $start).TotalMinutes) / ($R - 1), 3)
  }

  $target = 0
  $A = [double]$st.seg.lastA
  if ($R -ge 100) { $target = 2 }
  elseif ($R -ge 50 -and $A -le 2) { $target = 1 }
  if ($target -gt [int]$st.fatigue) {
    $st.fatigue = $target
    $st.fatigueAt = Iso $now
  }
  return $st
}

function DoSet($st, $label) {
  if ($All -notcontains $label) { return $st }
  if ([int]$st.fatigue -ge 2) { return $st }          # 锁槽：不收新情绪

  # 互斥：先踢掉冲突的那格
  foreach ($pair in $Exclusive) {
    if ($pair -contains $label) {
      $other = $pair | Where-Object { $_ -ne $label }
      $st.slots = @($st.slots | Where-Object { $_.label -ne $other })
    }
  }

  # 同类叠加：刷新时间，不占新位
  $same = @($st.slots | Where-Object { $_.label -eq $label })
  if ($same.Count -gt 0) {
    $same[0].at = Iso (Now)
    return $st
  }

  if (@($st.slots).Count -lt 2) {
    $st.slots = @($st.slots) + [pscustomobject]@{ label = $label; at = (Iso (Now)) }
    return $st
  }

  $now = Now
  $newHeavy = IsHeavy $label
  if ($newHeavy) {
    $lightSlots = @($st.slots | Where-Object { -not (IsHeavy $_.label) })
    if ($lightSlots.Count -gt 0) {
      $victim = $lightSlots | Sort-Object at | Select-Object -First 1
      $st.slots = @($st.slots | Where-Object { $_.label -ne $victim.label })
    } else {
      $victim = $st.slots | Sort-Object at | Select-Object -First 1
      $st.slots = @($st.slots | Where-Object { $_.label -ne $victim.label })
    }
    $st.slots = @($st.slots) + [pscustomobject]@{ label = $label; at = (Iso $now) }
    return $st
  }

  # 新的是轻情绪：槽里若有重情绪，且那格已过一半寿命才可顶替
  $heavySlots = @($st.slots | Where-Object { IsHeavy $_.label })
  if ($heavySlots.Count -gt 0) {
    $h = $heavySlots | Sort-Object at | Select-Object -First 1
    $age = ($now - (Parse $h.at)).TotalMinutes
    if ($age -ge ([math]::Round((LifeOf $h.label) / 2, 1))) {
      $st.slots = @($st.slots | Where-Object { $_.label -ne $h.label })
      $st.slots = @($st.slots) + [pscustomobject]@{ label = $label; at = (Iso $now) }
    }
    return $st
  }

  $victim = $st.slots | Sort-Object at | Select-Object -First 1
  $st.slots = @($st.slots | Where-Object { $_.label -ne $victim.label })
  $st.slots = @($st.slots) + [pscustomobject]@{ label = $label; at = (Iso (Now)) }
  return $st
}

$st = Load

# 换会话：旧情绪一律不带走
if ($Session -ne '' -and $Session -ne $st.sessionId) {
  $st = [pscustomobject]@{
    sessionId = $Session; updatedAt = (Iso (Now)); slots = @()
    seg = [pscustomobject]@{ startAt = $null; lastUserAt = $null; count = 0; lastA = 0 }
    fatigue = 0; fatigueAt = $null; lock = $false
  }
  Save $st
}

if ($Reset) {
  $st = [pscustomobject]@{
    sessionId = ''; updatedAt = (Iso (Now)); slots = @()
    seg = [pscustomobject]@{ startAt = $null; lastUserAt = $null; count = 0; lastA = 0 }
    fatigue = 0; fatigueAt = $null; lock = $false
  }
  Save $st
  Write-Output 'emotion: reset'
  return
}

if ($Tick) { $st = DoTick $st }
if ($Set -ne '') { $st = DoSet $st $Set }
if ($Expire) {
  $st = ApplyExpire $st
  $lastUser = Parse $st.seg.lastUserAt
  if ($lastUser -and ((Now) - $lastUser).TotalMinutes -gt $SegGap) { $st.seg.count = 0 }
}
if ($Tick -or $Set -ne '' -or $Expire) { Save $st }

if ($Show -or (-not ($Tick -or $Expire) -and $Set -eq '')) {
  $labels = @($st.slots | ForEach-Object { $_.label })
  $slotText = if ($labels.Count -eq 0) { '空' } else { ($labels -join ' + ') }
  Write-Output ("emotion: slots=[{0}] fatigue={1} lock={2} R={3} A={4}min" -f $slotText, $st.fatigue, $st.lock, $st.seg.count, $st.seg.lastA)
}
