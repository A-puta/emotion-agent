# 外部哨兵脚本 (ASCII-only on purpose: PS 5.1 reads .ps1 as ANSI, so all Chinese lives in config.json)
# Every N minutes decide whether to proactively send one small message to QQ.
# Generate via DeepSeek API. Deliver via the dsh-im proactive-delivery endpoint.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File <this> [-Status] [-DryRun] [-Force]

param([switch]$DryRun, [switch]$Force, [switch]$Status, [switch]$Probe, [switch]$ShowPrompt, [string]$TagName = '', [int]$Count = 5)

$ErrorActionPreference = 'Stop'
$root      = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath   = Join-Path $root 'config.json'
$statePath = Join-Path $root 'state.json'
$logPath   = Join-Path $root 'sentinel.log'
$script:logEnabled = $true
$credPath  = Join-Path $env:USERPROFILE '.dsh\.credentials.yaml'

function Log([string]$msg) {
  $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  if ($script:logEnabled) { try { Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8 } catch { } }
  if ($DryRun -or $Status -or $Probe -or $ShowPrompt) { Write-Host $line }
}
function ReadJson([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function WriteJson([string]$p, $o) {
  [IO.File]::WriteAllText($p, ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
}
function ExpHours([double]$meanHours) {
  $u = Get-Random -Minimum 0.0001 -Maximum 1.0
  return (-[Math]::Log($u)) * $meanHours
}
# Interval between two messages: uniform random in [minHours, maxHours] (default), or exponential.
function RandIntervalHours($c) {
  $mode = 'uniform'
  if ($c.interval -and $c.interval.mode) { $mode = [string]$c.interval.mode }
  if ($mode -eq 'exponential') { return (ExpHours ([double]$c.limits.meanIntervalHours)) }
  $lo = 4.0; $hi = 15.0
  if ($c.interval) {
    if ($c.interval.minHours) { $lo = [double]$c.interval.minHours }
    if ($c.interval.maxHours) { $hi = [double]$c.interval.maxHours }
  }
  if ($hi -le $lo) { $hi = $lo + 1.0 }
  return $lo + (Get-Random -Minimum 0.0 -Maximum 1.0) * ($hi - $lo)
}
function PickTag($c) {
  $t = @($c.tags)
  if ($t.Count -eq 0) { return '关心' }
  return [string]$t[(Get-Random -Minimum 0 -Maximum $t.Count)]
}
# Is a timestamp inside the quiet window? Time-of-day only; handles a window that crosses midnight.
function Test-QuietStamp([datetime]$stamp, [int]$startHour, [int]$endHour) {
  $hh = $stamp.Hour
  if ($startHour -lt $endHour) { return ($hh -ge $startHour -and $hh -lt $endHour) }
  return ($hh -ge $startHour -or $hh -lt $endHour)
}
# Weighted pick over a JSON object of name -> weight.
function PickWeighted($weights) {
  $names = @($weights.PSObject.Properties.Name)
  $total = 0.0
  foreach ($k in $names) { $total += [double]$weights.$k }
  if ($total -le 0) { return $names[0] }
  $r = Get-Random -Minimum 0.0 -Maximum $total
  $acc = 0.0
  foreach ($k in $names) {
    $acc += [double]$weights.$k
    if ($r -le $acc) { return $k }
  }
  return $names[$names.Count - 1]
}
# One weighted pool: every ordinary message draws from tagPlan.weights (no sentinel/random split).
function PickTagPlanned($c) {
  $w = $null
  if ($c.tagPlan -and $c.tagPlan.weights) { $w = $c.tagPlan.weights }
  if (-not $w) { return @{ tag = (PickTag $c); branch = 'random' } }
  return @{ tag = (PickWeighted $w); branch = 'random' }
}
# --- hard de-duplication: char-bigram Jaccard similarity on text with punctuation/emoji stripped ---
function NormText([string]$s) {
  if (-not $s) { return '' }
  return ($s -replace '[\s\p{P}\p{S}]', '')
}
function Bigrams([string]$s) {
  # NOTE: never returned from a function (PowerShell unrolls IEnumerable on return, which breaks .Contains).
  $set = New-Object 'System.Collections.Generic.HashSet[string]'
  if ($s.Length -eq 0) { return $set }
  if ($s.Length -eq 1) { $null = $set.Add($s); return $set }
  for ($i = 0; $i -lt $s.Length - 1; $i++) { $null = $set.Add($s.Substring($i, 2)) }
  return $set
}
function Similarity([string]$left, [string]$right) {
  # NOTE: do NOT name locals like the (type-constrained) parameters: PS is case-insensitive,
  # so `$A = ...` inside a function that has `[string]$a` would be coerced back to a string.
  $ta = NormText $left; $tb = NormText $right
  $setA = New-Object 'System.Collections.Generic.HashSet[string]'
  $setB = New-Object 'System.Collections.Generic.HashSet[string]'
  if ($ta.Length -eq 1) { $null = $setA.Add($ta) }
  for ($i = 0; $i -lt $ta.Length - 1; $i++) { $null = $setA.Add($ta.Substring($i, 2)) }
  if ($tb.Length -eq 1) { $null = $setB.Add($tb) }
  for ($j = 0; $j -lt $tb.Length - 1; $j++) { $null = $setB.Add($tb.Substring($j, 2)) }
  if ($setA.Count -eq 0 -or $setB.Count -eq 0) { return 0.0 }
  $inter = 0
  foreach ($x in $setA) { if ($setB.Contains($x)) { $inter++ } }
  $union = $setA.Count + $setB.Count - $inter
  if ($union -le 0) { return 0.0 }
  return [double]$inter / [double]$union
}
function MaxSimilarity([string]$cand, $recent, [int]$limit) {
  $worst = 0.0
  $n = 0
  foreach ($r in @($recent)) {
    if ($n -ge $limit) { break }
    $s = Similarity $cand ([string]$r)
    if ($s -gt $worst) { $worst = $s }
    $n++
  }
  return $worst
}
# PS 5.1's Invoke-RestMethod decodes JSON as Latin-1 when the response has no charset -> Chinese becomes mojibake.
# So always read raw bytes and decode UTF-8 ourselves.
function Get-JsonUtf8([string]$uri, [int]$timeoutSec = 15) {
  $wr = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $timeoutSec
  return ([Text.Encoding]::UTF8.GetString($wr.RawContentStream.ToArray()) | ConvertFrom-Json)
}
function Post-JsonUtf8([string]$uri, $headers, [string]$json, [int]$timeoutSec = 90) {
  $wr = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' `
          -Body ([Text.Encoding]::UTF8.GetBytes($json)) -UseBasicParsing -TimeoutSec $timeoutSec
  return ([Text.Encoding]::UTF8.GetString($wr.RawContentStream.ToArray()) | ConvertFrom-Json)
}

$cfg = ReadJson $cfgPath
if (-not $cfg) { Log "FATAL: config.json missing or broken"; exit 1 }
$script:logEnabled = $true
if ($cfg.logging -eq $false) { $script:logEnabled = $false }

# ---------- missing-phase settings (night hold -> wake hold) ----------
$missingFixed = 60
$missingTags = @()
$missingFreeTags = @()
$missingWeights = $null
if ($cfg.missing -and $cfg.missing.rules -and $cfg.missing.rules.missingPhase) {
  $mp = $cfg.missing.rules.missingPhase
  if ($mp.fixedMinutes) { $missingFixed = [int]$mp.fixedMinutes }
  if ($mp.tags) { $missingTags = @($mp.tags) }
  if ($mp.freeTags) { $missingFreeTags = @($mp.freeTags) }
  if ($mp.weights) { $missingWeights = $mp.weights }
}

# ---------- status mode ----------
if ($Status) {
  $tn = [string]$cfg.taskName
  $reg = $false
  try { $q = schtasks /Query /TN $tn /FO CSV /NH 2>$null; if ($q) { $reg = $true } } catch { }
  $nextRun = '-'
  try {
    $v = schtasks /Query /TN $tn /FO LIST /V 2>$null | Select-String -Pattern 'Next Run Time' | Select-Object -First 1
    if ($v) { $nextRun = ($v.Line -split ':', 2)[1].Trim() }
  } catch { }
  $stNow = ReadJson $statePath
  $today = (Get-Date).ToString('yyyy-MM-dd')
  $cnt = 0
  if ($stNow -and $stNow.todayDate -eq $today) { $cnt = [int]$stNow.todayCount }
  $last = 'never'
  if ($stNow -and $stNow.lastSentAt) { $last = ([datetime]$stNow.lastSentAt).ToString('MM-dd HH:mm') }
  $next = '-'
  if ($stNow -and $stNow.nextEligibleAt) { $next = ([datetime]$stNow.nextEligibleAt).ToString('MM-dd HH:mm') }
  $lastMsg = '-'
  if ($stNow -and @($stNow.recent).Count -gt 0) { $lastMsg = [string]@($stNow.recent)[0] }
  $regTxt = 'MISSING'
  if ($reg) { $regTxt = 'registered' }
  $modeTxt = 'normal'
  if ($stNow -and $stNow.missingPhase) { $modeTxt = 'missing-phase' }
  elseif ($stNow -and $stNow.nightHeld) { $modeTxt = 'night-hold' }
  $lines = @(
    ("external sentinel: {0}  [{1}]" -f $tn, $regTxt),
    ("mode               : {0}" -f $modeTxt),
    ("next scheduled run : {0}" -f $nextRun),
    ("last sent          : {0}" -f $last),
    ("today              : {0}/{1}" -f $cnt, $cfg.limits.maxPerDay),
    ("next eligible      : {0}" -f $next),
    ("last message       : {0}" -f $lastMsg)
  )
  $out = ($lines -join "`r`n")
  [IO.File]::WriteAllText((Join-Path $root 'status.txt'), $out, (New-Object Text.UTF8Encoding($false)))
  Write-Output $out
  exit 0
}

# ---------- state ----------
$st = ReadJson $statePath
if (-not $st) {
  $st = [pscustomobject]@{ lastSentAt = $null; todayDate = ''; todayCount = 0; nextEligibleAt = $null; recent = @(); lastDecision = ''; lastTag = $null; nightHeld = $false; missingPhase = $false; lastChideAt = $null }
}
# state files written by hand (or by an older build) may miss a field: a PS custom object refuses to
# assign an unknown property, which used to break the commit path AFTER the message was delivered.
$stateFields = [ordered]@{
  lastSentAt = $null; todayDate = ''; todayCount = 0; nextEligibleAt = $null
  recent = @(); lastDecision = ''; lastTag = $null; nightHeld = $false; missingPhase = $false; lastChideAt = $null
  silenceBase = $null
}
foreach ($name in @($stateFields.Keys)) {
  if (-not (@($st.PSObject.Properties.Name) -contains $name)) { $st | Add-Member -NotePropertyName $name -NotePropertyValue $stateFields[$name] }
}
$now = Get-Date
$today = $now.ToString('yyyy-MM-dd')
if ($st.todayDate -ne $today) { $st.todayDate = $today; $st.todayCount = 0 }

# ---------- silence base: the user's own last message (user-specified 2026-10-18) ----------
$lastUserMs = 0
try {
  $luOut = & (Join-Path $root 'last-user-msg.ps1') 2>$null | Out-String
  if ($luOut -and $luOut.Trim() -match '^\d+$') { $lastUserMs = [long]$luOut.Trim() }
} catch { $lastUserMs = 0 }
$silenceMin = 99999
if ($lastUserMs -gt 0) {
  $silenceMin = ($now - ([DateTimeOffset]::FromUnixTimeMilliseconds($lastUserMs).LocalDateTime)).TotalMinutes
}
# a new user message invalidates the old arm: the interval is drawn again once silence reaches the threshold
if ($lastUserMs -gt 0 -and [string]$st.silenceBase -ne [string]$lastUserMs) {
  $st.silenceBase = $lastUserMs
  if (-not $st.missingPhase) {
    $st.nextEligibleAt = $null
    Log 'silence base moved -> interval will be redrawn'
  }
  WriteJson $statePath $st
}
# ---------- 思念值（missing value）：由 missing.ps1 判定（等级 C/B/A） ----------
$misDec = $null
$misSend = $true
$misTag = ''
$misLevel = 'C'
$misReason = ''
$misHold = $false
try {
  $misOut = & (Join-Path $root 'missing.ps1') -Decide 2>$null | Out-String
  if ($misOut) { $misDec = ($misOut.Trim() | ConvertFrom-Json) }
} catch { $misDec = $null }
if ($misDec) {
  if ($misDec.action) { $misSend = ($misDec.action -eq 'send') }
  $misLevel = [string]$misDec.level
  $misReason = [string]$misDec.reason
  if ($misDec.missing -eq $true) { $misTag = '思念' }
  Log ("missing value: level={0} action={1} reply={2} shy={3} why={4}" -f $misDec.level, $misDec.action, $misDec.replied, $misDec.shyStreak, $misDec.reason)
}
# C 级的"不发送"只表示这次不说思念/不掷升级，日常话语照常投；B/A 的"不发送"以及"刚聊过"才作废整轮。
# 而且夜间沉默与思念期上膛优先度更高，真正的拦截放在上膛之后（见 gates 内）。
if (-not $misSend) {
  if (($misLevel -eq 'C') -and (-not $misDec.replied)) {
    Log 'missing value: C-level skip only -- the daily throw still goes out'
  } else {
    $misHold = $true
  }
}
# 被晾着（A 级连着发满 N 条没被回应）：只停止发思念。
# 2026-10-23 用户取消"思念得不到回复就生气"这条逻辑，不再调用 anger.ps1 -Neglect。
if ($misDec -and $misDec.neglect -eq $true) {
  Log 'neglect: missing messages ignored -> stop sending (anger untouched)'
}


# ---------- gates ----------
if (-not ($Force -or $Probe -or $ShowPrompt)) {
  # the missing phase runs its own fixed cadence and may send free tags, so the daily quota and the
  # ordinary minimum gap only guard the normal branch; in the phase a full quota just forces a free tag.
  if (-not $st.missingPhase -and $st.todayCount -ge $cfg.limits.maxPerDay) { Log "skip: already sent $($st.todayCount) today"; WriteJson $statePath $st; exit 0 }

  if ($st.lastSentAt -and -not $st.missingPhase) {
    $gap = ($now - [datetime]$st.lastSentAt).TotalMinutes
    if ($gap -lt $cfg.limits.minGapMinutes) { Log ("skip: only {0:N0} min since last message" -f $gap); WriteJson $statePath $st; exit 0 }
  }

  $h = $now.Hour
  $qs = [int]$cfg.limits.quietStart; $qe = [int]$cfg.limits.quietEnd
  $quiet = Test-QuietStamp $now $qs $qe
  $due = [bool]($st.nextEligibleAt -and ($now -ge [datetime]$st.nextEligibleAt))
  # a throw may only arm the missing phase when its own scheduled time fell inside the quiet window
  $heldInWindow = [bool]($st.nextEligibleAt -and $due -and (Test-QuietStamp ([datetime]$st.nextEligibleAt) $qs $qe))

  if ($quiet) {
    # missing rule 1 (night hold): stay silent; only a throw that came due inside the window is held
    if ($heldInWindow) {
      $retry = 60
      if ($cfg.missing -and $cfg.missing.rules -and $cfg.missing.rules.nightHold -and $cfg.missing.rules.nightHold.retryMinutes) {
        $retry = [int]$cfg.missing.rules.nightHold.retryMinutes
      }
      $st.nextEligibleAt = $now.AddMinutes($retry).ToString('s')
      $st.lastDecision = 'missing-rule1-night-hold'
      $st.nightHeld = $true
      Log ("hold: night window {0}:00-{1}:00 -> next eligible in {2} min (missing rule 1)" -f $qs, $qe, $retry)
      WriteJson $statePath $st
    }
    exit 0
  }

  # ---------- missing phase (wake hold) ----------
  # Entered only because a throw was scheduled inside the night window: either it was observed being
  # held during the night (nightHeld), or the machine was off and the pending in-window throw is found
  # after the window on the same day. Merely reaching quietEnd never starts the phase.
  if (-not $st.missingPhase) {
    $backfill = [bool]($qs -lt $qe -and $h -ge $qe -and $st.nextEligibleAt -and $due -and (Test-QuietStamp ([datetime]$st.nextEligibleAt) $qs $qe) -and ([datetime]$st.nextEligibleAt).Date -eq $now.Date)
    if ($st.nightHeld -or $backfill) {
      $wakeAt = Get-Date -Hour $qe -Minute 0 -Second 0
      $why = 'night-hold'; if ($backfill) { $why = 'backfill' }
      $st.nightHeld = $false
      $st.missingPhase = $true
      $st.nextEligibleAt = $wakeAt.AddMinutes($missingFixed).ToString('s')
      $st.lastDecision = 'missing-phase-armed'
      Log ("missing phase armed ({0}): wake {1}:00 + {2} min -> next eligible {3}" -f $why, $qe, $missingFixed, $st.nextEligibleAt)
      WriteJson $statePath $st
    }
  }

  # 思念值的拦截放在这里：夜间沉默与思念期上膛已经处理完，不会被它吞掉。
  if ($misHold) {
    Log 'skip: missing value says this throw is withheld'
    $st.lastDecision = 'missing-value-skip'
    WriteJson $statePath $st
    exit 0
  }

  # silence counts from the user's own last message (computed above)
  if ($silenceMin -lt ($cfg.limits.minSilenceHours * 60)) {
    Log ("skip: talked {0:N0} min ago" -f $silenceMin); WriteJson $statePath $st; exit 0
  }

  # foreground app
  Add-Type @"
using System;using System.Runtime.InteropServices;
public class Sf {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@ -ErrorAction SilentlyContinue
  $fgName = ''; $fgPath = ''
  try {
    $hWnd = [Sf]::GetForegroundWindow(); $fpid = 0
    [Sf]::GetWindowThreadProcessId($hWnd, [ref]$fpid) | Out-Null
    $fp = Get-Process -Id $fpid -ErrorAction SilentlyContinue
    if ($fp) { $fgName = $fp.ProcessName; $fgPath = [string]$fp.Path }
  } catch { }

  # game = exe inside a Steam library, or a known game process name
  $isGame = $false
  if ($fgPath) {
    foreach ($lib in $cfg.gameLibraryFiles) {
      if (-not (Test-Path -LiteralPath $lib)) { continue }
      $dir = Split-Path -Parent (Split-Path -Parent $lib)
      if ($fgPath.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { $isGame = $true; break }
    }
  }
  if (-not $isGame -and $fgName) {
    foreach ($g in $cfg.gameProcessNames) { if ($fgName -like "*$g*") { $isGame = $true; break } }
  }
  $isWork = $false
  foreach ($w in $cfg.appRules.work) { if ($fgName -like "*$w*") { $isWork = $true; break } }
  if ($isWork -and -not $isGame) { Log "skip: user is working ($fgName)"; WriteJson $statePath $st; exit 0 }

  # poisson gate + hold-back dice
  if (-not $st.nextEligibleAt) {
    $mins = [int]((RandIntervalHours $cfg) * 60)
    $st.nextEligibleAt = $now.AddMinutes($mins).ToString('s'); $st.lastDecision = 'armed'
    Log ("arm: next eligible in {0:N0} min" -f $mins); WriteJson $statePath $st; exit 0
  }
  if ($now -lt [datetime]$st.nextEligibleAt) { WriteJson $statePath $st; exit 0 }

  if ((Get-Random -Minimum 0.0 -Maximum 1.0) -gt $cfg.limits.sendProbability) {
    # in the missing phase a missed throw keeps the fixed gap; otherwise draw the ordinary interval
    $mins = [int]((RandIntervalHours $cfg) * 60)
    if ($st.missingPhase) { $mins = $missingFixed }
    $st.nextEligibleAt = $now.AddMinutes($mins).ToString('s'); $st.lastDecision = 'held-back'
    Log ("held back (thought about it, kept quiet); next in {0:N0} min" -f $mins); WriteJson $statePath $st; exit 0
  }
} else {
  $silenceMin = 0; $fgName = 'Forced'; $isGame = $false; $isWork = $false
}

# ---------- anger gate (anger outranks the sentinel) ----------
# Read-only: the sentinel never writes anger.json. Session mismatch => treat as -1.
if (-not ($Probe -or $ShowPrompt) -and $cfg.angerGate -and $cfg.angerGate.enabled) {
  $angerLevel = -1
  try {
    $a = ReadJson ([string]$cfg.angerGate.statePath)
    if ($a) {
      $sessRoot2 = Join-Path $env:USERPROFILE '.dsh\sessions'
      $newest2 = Get-ChildItem -LiteralPath $sessRoot2 -Recurse -File -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
      $curSid = ''
      if ($newest2) { $curSid = $newest2.Directory.Name }
      if ((-not $a.sessionId) -or ($a.sessionId -eq $curSid)) { $angerLevel = [int]$a.anger }
      else { $angerLevel = -1 }
    }
  } catch { }
  $angerLimit = 0
  if ($cfg.angerGate.skipWhenAbove -ne $null) { $angerLimit = [int]$cfg.angerGate.skipWhenAbove }
  if ($angerLevel -gt $angerLimit) {
    Log ("skip: anger=$angerLevel > $angerLimit (anger outranks the sentinel)")
    exit 0
  }
}

$angerShown = 'n/a'
if ($null -ne $angerLevel) { $angerShown = [string]$angerLevel }
Log ("gates passed -> generating [today={0}/{1}; silence={2:N0}min; fg={3}; anger={4}; nextEligible={5}]" -f $st.todayCount, $cfg.limits.maxPerDay, $silenceMin, $fgName, $angerShown, $st.nextEligibleAt)

# ---------- signals ----------
$weatherText = '(no data)'
$city = $cfg.city
if ($cfg.autoLocate) {
  try {
    $geoIp = Get-JsonUtf8 'https://api.ip.sb/geoip' 12
    if ($geoIp.city) { $city = $geoIp.city }
  } catch { }
}
try {
  $g = Get-JsonUtf8 ("https://geocoding-api.open-meteo.com/v1/search?name={0}&count=1&language=zh" -f [uri]::EscapeDataString($city)) 15
  if ($g.results -and $g.results.Count -gt 0) {
    $r0 = $g.results[0]
    $w = Get-JsonUtf8 ("https://api.open-meteo.com/v1/forecast?latitude={0}&longitude={1}&current=temperature_2m,weather_code,precipitation&timezone=Asia%2FShanghai" -f $r0.latitude, $r0.longitude) 15
    $code = [string]$w.current.weather_code
    $desc = $cfg.weatherCodes.$code
    if (-not $desc) { $desc = "code $code" }
    $rain = if ([double]$w.current.precipitation -gt 0) { ', raining now' } else { '' }
    $weatherText = "{0} {1}C {2}{3}" -f $r0.name, $w.current.temperature_2m, $desc, $rain
  }
} catch { Log "weather lookup failed: $($_.Exception.Message)" }

$recentList = ''   # kept local only: used by the de-duplication step, never sent to the API
if (@($st.recent).Count -gt 0) { $recentList = 'local' }

$weekday = @('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')[[int]$now.DayOfWeek]
$silenceText = if ($Force) { 'a long while' } else { "{0:N1} hours" -f ($silenceMin / 60) }
# Privacy: only the CATEGORY leaves this machine. The process name stays in the local log.
$appCategory = 'other'
if ($isGame) { $appCategory = 'game' } elseif ($isWork) { $appCategory = 'work' }
$appText = $appCategory
$tagPlan = PickTagPlanned $cfg
$tag = [string]$tagPlan.tag
$branch = [string]$tagPlan.branch
if ($st.missingPhase -and $missingTags.Count -gt 0) {
  # during the missing phase only the configured tags go out, weighted (default 1:1)
  if ($missingWeights) { $tag = [string](PickWeighted $missingWeights) }
  else { $tag = [string]$missingTags[(Get-Random -Minimum 0 -Maximum $missingTags.Count)] }
  $branch = 'missing'
}
if ($TagName) { $tag = $TagName }
# 思念值指定本次必须发 <思念>（A 级每次 / B 级 60% 命中）时，强制标签并按等级取对应文案规则
$degMap = @{ 'C' = '思念C'; 'B' = '思念B'; 'A' = '思念A' }
if ($misTag) {
  $tag = $misTag
  $deg = $degMap[$misLevel]
  if (-not $deg) { $deg = '思念C' }
  if ($cfg.tagRules -and $cfg.tagRules.$deg) { $tag = $deg }
  $branch = 'missing-value'
  Log ("missing value forces tag -> {0}" -f $tag)
}
# a free tag never occupies the daily capacity; once the paid quota is used up only free tags may leave
$tagIsFree = [bool]($missingFreeTags -contains $tag)
if ($st.missingPhase -and -not $tagIsFree -and $st.todayCount -ge $cfg.limits.maxPerDay) {
  if ($missingFreeTags.Count -gt 0) { $tag = [string]$missingFreeTags[0]; $tagIsFree = $true; Log "quota full: this throw can only be answered by the free tag" }
  else { Log "skip: quota full and no free tag configured"; WriteJson $statePath $st; exit 0 }
}
# a weather-dependent tag may only go out when the lookup really returned data; otherwise the throw
# falls back to a draw among the tags that do not need weather (same weights as the current pool).
$weatherTags = @()
if ($cfg.weatherTags) { $weatherTags = @($cfg.weatherTags) }
if (($weatherText -eq '(no data)') -and ($weatherTags -contains $tag)) {
  $poolWeights = $null
  if ($st.missingPhase -and $missingWeights) { $poolWeights = $missingWeights }
  elseif (-not $st.missingPhase -and $cfg.tagPlan -and $cfg.tagPlan.weights) { $poolWeights = $cfg.tagPlan.weights }
  $altTags = @()
  if ($poolWeights) { $altTags = @(@($poolWeights.PSObject.Properties.Name) | Where-Object { $weatherTags -notcontains $_ }) }
  if ($altTags.Count -eq 0) { $altTags = @(@($cfg.tags) | Where-Object { $weatherTags -notcontains $_ }) }
  if ($altTags.Count -gt 0) {
    $pick = $null
    if ($poolWeights) {
      $sub = [pscustomobject]@{}
      foreach ($n in $altTags) { $sub | Add-Member -NotePropertyName $n -NotePropertyValue ([double]$poolWeights.$n) }
      $pick = [string](PickWeighted $sub)
    }
    if (-not $pick) { $pick = [string]$altTags[(Get-Random -Minimum 0 -Maximum $altTags.Count)] }
    Log ("weather unavailable: tag {0} -> {1}" -f $tag, $pick)
    $tag = $pick
    $tagIsFree = [bool]($missingFreeTags -contains $tag)
  }
}
$tagRule = ''
if ($cfg.tagRules -and $cfg.tagRules.$tag) { $tagRule = [string]$cfg.tagRules.$tag }
$lastTag = '-'
if ($st.lastTag) { $lastTag = [string]$st.lastTag }

$sys = [string]$cfg.prompts.system
$usr = [string]$cfg.prompts.user
$usr = $usr.Replace('{now}', $now.ToString('yyyy-MM-dd HH:mm')).Replace('{weekday}', $weekday).
            Replace('{silence}', $silenceText).Replace('{weather}', $weatherText).
            Replace('{app}', $appText).Replace('{limit}', [string]$cfg.textLimit).
            Replace('{tag}', $tag).Replace('{tagRule}', $tagRule).Replace('{lastTag}', $lastTag)

# Audit switch: show exactly what would be sent (no API call, nothing sent)
if ($ShowPrompt) {
  $rep = @("=== SYSTEM ===", $sys, "=== USER ===", $usr) -join "`r`n"
  Write-Output $rep
  exit 0
}

# ---------- generate ----------
$key = $null
try {
  $cred = [IO.File]::ReadAllText($credPath, [Text.Encoding]::UTF8)
  $m = [regex]::Match($cred, 'DEEPSEEK_API_KEY:\s*(\S+)')
  if ($m.Success) { $key = $m.Groups[1].Value }
} catch { }
if (-not $key) { Log "FATAL: no DEEPSEEK_API_KEY in credentials"; exit 1 }

$simLimit = 0.55; $triesMax = 3; $cmpLimit = 20
if ($cfg.dedupe) {
  if ($cfg.dedupe.maxSimilarity) { $simLimit = [double]$cfg.dedupe.maxSimilarity }
  if ($cfg.dedupe.retries) { $triesMax = [int]$cfg.dedupe.retries + 1 }
  if ($cfg.dedupe.compareRecent) { $cmpLimit = [int]$cfg.dedupe.compareRecent }
}

function New-Message([string]$sysText, [string]$usrText, $recent, [string]$apiKey, [int]$tries) {
  $best = ''; $bestSim = 99.0
  for ($a = 1; $a -le $tries; $a++) {
    $b = @{
      model       = $cfg.model
      messages    = @(@{ role = 'system'; content = $sysText }, @{ role = 'user'; content = $usrText })
      max_tokens  = [int]$cfg.maxTokens
      temperature = [double]$cfg.temperature
      thinking    = @{ type = 'disabled' }
    } | ConvertTo-Json -Depth 8 -Compress
    try {
      $resp = Post-JsonUtf8 'https://api.deepseek.com/chat/completions' @{ Authorization = "Bearer $apiKey" } $b 90
    } catch {
      Log "generate failed: $($_.Exception.Message)"
      if ($_.ErrorDetails) { Log ("api: " + $_.ErrorDetails.Message) }
      return @{ text = ''; sim = 99.0; tries = $a; error = $true }
    }
    $cand = [string]$resp.choices[0].message.content
    $cand = ($cand -replace '[\r\n]+', ' ').Trim().Trim('"').Trim("'")
    if ($cand.Length -gt 120) { $cand = $cand.Substring(0, 120) }
    if (-not $cand) { continue }
    $sim = MaxSimilarity $cand $recent $cmpLimit
    if ($sim -lt $bestSim) { $bestSim = $sim; $best = $cand }
    if ($sim -le $simLimit) { return @{ text = $cand; sim = $sim; tries = $a; error = $false } }
    Log ("attempt {0}: too similar ({1:N2}): {2}" -f $a, $sim, $cand)
  }
  return @{ text = ''; sim = $bestSim; tries = $tries; error = $false; best = $best }
}

# probe mode: generate N candidates for one tag and print them with their max similarity (never sends)
if ($Probe) {
  $probeRecent = @($st.recent)
  $lines = @()
  for ($i = 1; $i -le $Count; $i++) {
    $usrT = $usr.Replace('{tag}', $tag).Replace('{lastTag}', '-')
    $r = New-Message $sys $usrT $probeRecent $key $triesMax
    if (-not $r.text) { $lines += ("{0}. [rejected] best similarity {1:N2}" -f $i, $r.sim); continue }
    $lines += ("{0}. {1}" -f $i, $r.text)
    $lines += ("   max-sim vs earlier = {0:N2}   (tries {1})" -f $r.sim, $r.tries)
    $probeRecent = @($r.text) + $probeRecent
  }
  $joined = ("branch = {0}, tag = {1}, similarity limit = {2:N2}`r`n" -f $branch, $tag, $simLimit) + ($lines -join "`r`n")
  Write-Output $joined
  exit 0
}

# ---------- 出话方式：库挑（不花钱）还是模型现写 ----------
$sayMode = 'model'
try {
  $modeFile = Join-Path 'D:\DSH-资料\结衣状态' 'sentinel-mode.json'
  if (Test-Path $modeFile) { $sayMode = [string](Get-Content $modeFile -Raw -Encoding UTF8 | ConvertFrom-Json).mode }
} catch { }

$res = $null
if ($sayMode -eq 'library') {
  $pickScript = Join-Path $root 'pick_phrase.ps1'
  $fg = 'other'
  if ($appCategory -eq 'work') { $fg = 'work' } elseif ($appCategory -eq 'game') { $fg = 'game' }
  $pargs = @('-Show', '-SilenceHours', [string][math]::Round($silenceMin / 60, 2), '-Foreground', $fg)
  if ($weatherText -and $weatherText -ne '(no data)') { $pargs += @('-Weather', $weatherText) }
  $pickedRaw = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $pickScript @pargs 2>$null
  $pickedRaw = if ($pickedRaw) { ([string]$pickedRaw).Trim() } else { '' }
  if ($pickedRaw -match '^pick:\s*\[(.+?)\]\s*(.+)$') {
    $libTag = $Matches[1]
    $libText = $Matches[2].Trim()
    $res = @{ text = $libText; sim = 0.0; tries = 0; error = $false }
    Log ("library pick [" + $libTag + "]: " + $libText)
    # 标签映射：库里的分类 -> 思念逻辑认识的三类
    $tagMap = @{ '淘气' = '淘气'; '撒娇' = '淘气'; '好奇' = '好奇'; '小事' = '好奇'; '游戏' = '好奇'; '出门' = '好奇' }
    if ($tagMap.ContainsKey($libTag)) { $tag = $tagMap[$libTag] } else { $tag = '关心' }
  } else {
    Log 'library: 没有匹配的句子，回落到模型'
  }
}
if (-not $res) { $res = New-Message $sys $usr $st.recent $key $triesMax }
if ($res.error) { exit 1 }
if (-not $res.text) {
  if ($st.missingPhase) {
    $st.nextEligibleAt = $now.AddMinutes($missingFixed).ToString('s')
    $st.lastDecision = 'missing-phase-gave-up'
    WriteJson $statePath $st
  }
  Log ("give up: every candidate too similar (best {0:N2}); nothing sent" -f $res.sim); exit 0
}
$text = [string]$res.text
Log ("generated (branch {0}, tag {1}, tries {2}, max sim {3:N2}): {4}" -f $branch, $tag, $res.tries, $res.sim, $text)
if ($DryRun) { Write-Host ("[DRYRUN] would send: " + $text); exit 0 }

# ---------- deliver ----------
$payload = @{ botId = $cfg.delivery.botId; targetId = $cfg.delivery.targetId; text = $text } | ConvertTo-Json -Compress
Log ("delivering to {0}" -f $cfg.delivery.endpoint)
try {
  $sent = Post-JsonUtf8 $cfg.delivery.endpoint @{} $payload 30
} catch {
  Log "delivery failed: $($_.Exception.Message)"
  if ($_.ErrorDetails) { Log ("delivery detail: " + $_.ErrorDetails.Message) }
  exit 1
}
if (-not $sent.sent) { Log "delivery rejected: $($sent | ConvertTo-Json -Compress)"; exit 1 }

# A successful delivery is recorded FIRST, so a later state error can never hide it.
Log ("delivered ok (resp {0}); next eligible will be drawn now" -f ($sent | ConvertTo-Json -Compress))

# ---------- commit state (any failure must be visible, never silent) ----------
try {
  $st.lastSentAt = $now.ToString('s')
  # a free tag (missing) does not occupy the daily capacity
  if (-not $tagIsFree) { $st.todayCount = [int]$st.todayCount + 1 }
  $endingPhase = [bool]$st.missingPhase
  $st.missingPhase = $false
  $st.lastDecision = if ($endingPhase) { 'sent-missing-phase-end' } else { 'sent' }
  $st.lastTag = $tag
  $st.nextEligibleAt = $now.AddMinutes([int]((RandIntervalHours $cfg) * 60)).ToString('s')
  $newRecent = @($text)
  foreach ($m in @($st.recent)) { if ($newRecent.Count -lt [int]$cfg.recentLimit) { $newRecent += $m } }
  $st.recent = $newRecent
  WriteJson $statePath $st
  Log ("state committed: lastSentAt={0} today={1} nextEligible={2}" -f $st.lastSentAt, $st.todayCount, $st.nextEligibleAt)
  # 思念值：回报本次已发出（记 lastSentAt / lastTag），供下次判定"是否已产生对话"
  try {
    $mkArgs = @{ MarkSent = $true; Tag = $tag }
    $mk = & (Join-Path $root 'missing.ps1') @mkArgs 2>$null | Out-String
    Log ("missing value mark-sent: " + $mk.Trim())
  } catch {
    Log ("missing value mark-sent failed: {0}" -f $_.Exception.Message)
  }
} catch {
  Log ("STATE WRITE FAILED: {0} -- the message WAS delivered; counters are now stale, fix them by hand" -f $_.Exception.Message)
  exit 1
}
