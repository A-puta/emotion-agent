# 外部哨兵组的「怒气逻辑」脚本 (anger mechanic)
# ASCII-only on purpose: PS 5.1 reads .ps1 as ANSI, so no Chinese literals here.
# Usage:
#   anger.ps1                 -> show
#   anger.ps1 -Trigger        -> one more loop of a disallowed request (+1, cap 2); records peak; locks on 2 peaks within window
#   anger.ps1 -Malice         -> swearing/abuse: anger at least 1, waits for a promise (pact)
#   anger.ps1 -Pact           -> user promised not to swear again: clears the wait, anger -1
#   anger.ps1 -Lock           -> no promise made: go straight to lock (lockMinutes)
#   anger.ps1 -Tick           -> a normal turn ended without provocation (anger < 2 => -1)
#   anger.ps1 -Comfort        -> a comfort statement (semantic judgement is done by the caller)
#   anger.ps1 -TestTalk       -> this turn was test talk: no effect at all
#   anger.ps1 -Reset          -> the force-reset keyword (强制降低): back to minimum, lock cleared
#   anger.ps1 -Unlock         -> simulate the lock window ending (enters post-lock mode)
#   causes: trigger -> boundary (repeated disallowed request), malice -> malice (abusive words)
#   options: -Json, -StatePath <file> (for tests), -SessionId <id>

param(
  [switch]$Show, [switch]$Trigger, [switch]$Tick, [switch]$Comfort,
  [switch]$Reset, [switch]$TestTalk, [switch]$Unlock, [switch]$Json, [switch]$Neglect,
  [switch]$Malice, [switch]$Surge, [switch]$Pact, [switch]$Lock,
  [string]$StatePath = '', [string]$SessionId = ''
)

$ErrorActionPreference = 'Stop'
$root       = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath    = Join-Path $root 'anger.config.json'
$logPath    = Join-Path $root 'anger.log'
$script:logEnabled = $true

function ReadJson([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function WriteJsonAtomic([string]$p, $o) {
  $tmp = "$p.tmp"
  [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $p -Force
}
function Log([string]$msg) {
  if (-not $script:logEnabled) { return }
  Add-Content -LiteralPath $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) -Encoding UTF8
}
function EnsureField($obj, [string]$name, $value) {
  if ($null -eq $obj.$name) { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
}

$cfg = ReadJson $cfgPath
if (-not $cfg) {
  $cfg = [pscustomobject]@{ statePath = 'D:\DSH-资料\结衣状态\anger.json'; minAnger = -1; maxAnger = 2; lockMinutes = 30; peakWindowMinutes = 30; comfortsAfterLock = 2 }
}
if ($cfg.logging -eq $false) { $script:logEnabled = $false }
if (-not $StatePath) { $StatePath = [string]$cfg.statePath }
$minA = [int]$cfg.minAnger; $maxA = [int]$cfg.maxAnger
$now = Get-Date

# ---- session resolution: anger is per-session; a different session means baseline ----
if (-not $SessionId) {
  $sr = Join-Path $env:USERPROFILE '.dsh\sessions'
  $nf = Get-ChildItem -LiteralPath $sr -Recurse -File -Filter 'session.v4.jsonl.zstd' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($nf) { $SessionId = $nf.Directory.Name }
}
$st = ReadJson $StatePath
$isNewSession = $false
if (-not $st) { $isNewSession = $true }
elseif (-not $st.sessionId) { $isNewSession = $true }
elseif ($SessionId -and $st.sessionId -ne $SessionId) { $isNewSession = $true }

if ($isNewSession) {
  $st = [pscustomobject]@{
    sessionId = $SessionId; anger = $minA; loop = 0; comfortCount = 0; peaks = @()
    locked = $false; lockedAt = ''; lockUntil = ''; postLockPending = $false
    postLockComforts = 0; lastAction = ''; updatedAt = ''
  }
}
EnsureField $st 'loop' 0
EnsureField $st 'comfortCount' 0
EnsureField $st 'postLockComforts' 0
EnsureField $st 'locked' $false
EnsureField $st 'postLockPending' $false
EnsureField $st 'lockedAt' ''
EnsureField $st 'lockUntil' ''
EnsureField $st 'lastAction' ''
EnsureField $st 'updatedAt' ''
EnsureField $st 'peaks' @()
EnsureField $st 'neglect' $false
EnsureField $st 'causes' @()
EnsureField $st 'maliceCount' 0
EnsureField $st 'boundaryCount' 0
EnsureField $st 'lastCause' ''
EnsureField $st 'pactPending' $false
EnsureField $st 'pactAskedAt' ''
EnsureField $st 'pactBrokenCount' 0
EnsureField $st 'lockCount' 0
EnsureField $st 'maliceArmed' $false
if ($null -eq $st.anger) { $st | Add-Member -NotePropertyName anger -NotePropertyValue $minA -Force }

# ---- lock window expiry -> post-lock mode ----
if ($st.locked -and $st.lockUntil -and ($now -ge [datetime]$st.lockUntil)) {
  $st.locked = $false
  $st.postLockPending = $true
  $st.postLockComforts = 0
  Log 'lock window expired -> post-lock mode'
}

# ---- pick the action ----
$action = 'show'
if ($Trigger) { $action = 'trigger' }
elseif ($Tick) { $action = 'tick' }
elseif ($Comfort) { $action = 'comfort' }
elseif ($Reset) { $action = 'reset' }
elseif ($TestTalk) { $action = 'test-talk' }
elseif ($Unlock) { $action = 'unlock' }
elseif ($Neglect) { $action = 'neglect' }
elseif ($Malice) { $action = 'malice' }
elseif ($Surge) { $action = 'surge' }
elseif ($Pact) { $action = 'pact' }
elseif ($Lock) { $action = 'lock' }
$result = 'ok'

# 到顶就记一笔峰值；30 分钟内第二次到顶 -> 锁死。这是唯一的锁死入口。
# 原因标签：malice = 被恶意辱骂，boundary = 被反复触碰底线，both = 同一轮两者兼有
# 两类分开计数、分开留痕，互不覆盖；峰值与锁死仍按总数判断。
function Push-Cause([string]$tag) {
  $label = switch ($tag) {
    'malice'   { '被恶意辱骂' }
    'boundary' { '被反复触碰底线' }
    default    { '两种原因同时出现' }
  }
  $rec = [pscustomobject]@{ tag = $tag; label = $label; at = $now.ToString('s'); anger = [int]$st.anger; locked = [bool]$st.locked }
  $list = @($st.causes) + @($rec)
  if ($list.Count -gt 20) { $list = $list[($list.Count - 20)..($list.Count - 1)] }
  $st.causes = $list
  $st.lastCause = $tag
}

function Update-Peaks {
  if ([int]$st.anger -lt $maxA) { return 'up' }
  $cut = $now.AddMinutes(-1 * [int]$cfg.peakWindowMinutes)
  $kept = @()
  foreach ($p in @($st.peaks)) { if ($p -and ([datetime]$p) -ge $cut) { $kept += $p } }
  $kept += $now.ToString('s')
  $st.peaks = $kept
  if ((@($kept).Count -ge 2) -and (-not $st.locked)) {
    $st.locked = $true
    $st.lockCount = [int]$st.lockCount + 1
    $st.lockedAt = $now.ToString('s')
    $st.lockUntil = $now.AddMinutes([int]$cfg.lockMinutes).ToString('s')
    $st.postLockPending = $false
    $st.postLockComforts = 0
    return 'locked'
  }
  return 'peak'
}

switch ($action) {
  'trigger' {
    $st.loop = [int]$st.loop + 1
    $st.boundaryCount = [int]$st.boundaryCount + 1
    $st.anger = [Math]::Min($maxA, [int]$st.anger + 1)
    Push-Cause 'boundary'
    $result = Update-Peaks
  }
  'malice' {
    # 说脏话/辱骂（2026-10-24 用户新规）：
    # 第一次骂 -> 怒气到 1 并挂"等待约定"；
    # 若怒气还没降回 -1 又骂了一次 -> 直接到 2 并第一次锁死。
    $st.maliceCount = [int]$st.maliceCount + 1
    if ($st.maliceArmed -and -not $st.locked) {
      $st.anger = $maxA
      $st.pactPending = $false
      $st.pactAskedAt = ''
      Push-Cause 'malice'
      $st.locked = $true
      $st.lockedAt = $now.ToString('s')
      $st.lockUntil = $now.AddMinutes([int]$cfg.lockMinutes).ToString('s')
      $st.postLockPending = $true
      $st.postLockComforts = 0
      $st.lockCount = [int]$st.lockCount + 1
      $result = 'locked-by-repeat-malice'
    } else {
      if ([int]$st.anger -lt 1) { $st.anger = 1 }
      $st.maliceArmed = $true
      $st.pactPending = $true
      $st.pactAskedAt = $now.ToString('s')
      Push-Cause 'malice'
      $result = 'pact-asked'
    }
  }
  'pact' {
    # 对方答应以后不再说结衣坏话：撤掉待定，怒气落一格
    if ($st.pactPending) {
      $st.pactPending = $false
      $st.pactAskedAt = ''
      $st.anger = [Math]::Max($minA, [int]$st.anger - 1)
      $result = 'pact-accepted'
    } else {
      $result = 'no-pact-pending'
    }
  }
  'lock' {
    # 没答应约定 / 答应后又犯：进入锁死。
    # 时长 = 基础 lockMinutes + 每小时 60 分钟 x 违约次数（约定后每犯一次多锁 1 小时，累进）。
    $st.pactPending = $false
    $st.pactAskedAt = ''
    $st.pactBrokenCount = [int]$st.pactBrokenCount + 1
    $extraMin = 60 * [int]$st.pactBrokenCount
    $st.locked = $true
    $st.lockCount = [int]$st.lockCount + 1
    $st.lockedAt = $now.ToString('s')
    $st.lockUntil = $now.AddMinutes([int]$cfg.lockMinutes + $extraMin).ToString('s')
    $st.postLockPending = $false
    $st.postLockComforts = 0
    if ([int]$st.anger -lt $maxA) { $st.anger = $maxA }
    Push-Cause 'malice'
    $result = 'locked-by-pact'
  }
  'surge' {
    # 越界与恶意撞在同一轮：直接到顶，但不记峰值、不锁死
    $st.anger = $maxA
    Push-Cause 'both'
    $result = 'surged'
  }
  'tick' {
    if ($st.locked) { $result = 'locked-no-decay' }
    elseif ([int]$st.anger -lt $maxA) {
      $st.anger = [Math]::Max($minA, [int]$st.anger - 1)
      # 降回最低之后，"连续骂人"的计数才归零
      if ([int]$st.anger -le $minA) { $st.maliceArmed = $false }
      $result = 'decayed'
    } else { $result = 'at-max' }
  }
  'comfort' {
    if ($st.neglect) {
      # 被晾着的那份气：哄一下就好，直接回到最低，不留尾巴（不是锁死，也不进二级流程）
      $st.anger = $minA
      $st.neglect = $false
      $st.comfortCount = [int]$st.comfortCount + 1
      $result = 'neglect-cleared'
    }
    elseif ($st.locked) { $result = 'ignored-locked' }
    elseif ($st.postLockPending) {
      if ([int]$st.postLockComforts -eq 0) { $st.postLockComforts = 1; $result = 'postlock-first-rejected' }
      else {
        $st.anger = [Math]::Max($minA, [int]$st.anger - 1)
        $st.postLockComforts = [int]$cfg.comfortsAfterLock
        $st.postLockPending = $false
        $result = 'postlock-second-accepted'
      }
    }
    elseif ([int]$st.anger -ge $maxA) {
      $st.anger = [int]$st.anger - 1
      $st.comfortCount = [int]$st.comfortCount + 1
      $result = 'accepted'
    } else {
      $st.comfortCount = [int]$st.comfortCount + 1
      $result = 'noted'
    }
  }
  'neglect' {
    # 2026-10-23 起停用：思念得不到回复不再让结衣生气（规则已删）。
    $result = 'neglect-disabled'
  }
  'reset' {
    $st.anger = $minA; $st.locked = $false; $st.peaks = @()
    $st.postLockPending = $false; $st.postLockComforts = 0
    $st.loop = 0; $st.comfortCount = 0; $st.neglect = $false
    $st.causes = @(); $st.maliceCount = 0; $st.boundaryCount = 0; $st.lastCause = ''
    $st.pactPending = $false; $st.pactAskedAt = ''; $st.neglect = $false
    $st.lockCount = 0
    $result = 'reset'
    $st.maliceArmed = $false  # reset
  }
  'unlock' {
    if ($st.locked) { $st.locked = $false; $st.postLockPending = $true; $st.postLockComforts = 0; $result = 'lock-ended' }
    else { $result = 'not-locked' }
  }
  'test-talk' { $result = 'ignored-test' }
  default { $result = 'show' }
}

$st.lastAction = "$action/$result"
$st.updatedAt = $now.ToString('s')
WriteJsonAtomic $StatePath $st
Log ("action={0} result={1} anger={2} locked={3} peaks={4} postLock={5} cause={6} malice={7} boundary={8}" -f $action, $result, $st.anger, $st.locked, @($st.peaks).Count, $st.postLockComforts, $st.lastCause, [int]$st.maliceCount, [int]$st.boundaryCount)

$angry = 'no'; if ([int]$st.anger -gt 0) { $angry = 'yes' }
$lockedTxt = 'no'; if ($st.locked) { $lockedTxt = 'yes' }
$lockUntilTxt = '-'; if ($st.lockUntil) { $lockUntilTxt = ([datetime]$st.lockUntil).ToString('yyyy-MM-dd HH:mm:ss') }
$lines = @(
  ("action     : {0}  ({1})" -f $action, $result),
  ("anger      : {0}" -f $st.anger),
  ("angry      : {0}" -f $angry),
  ("loop       : {0}" -f $st.loop),
  ("locked     : {0}" -f $lockedTxt),
  ("lockUntil  : {0}" -f $lockUntilTxt),
  ("postLock   : {0}/{1}" -f $st.postLockComforts, [int]$cfg.comfortsAfterLock),
  ("peaks      : {0}" -f @($st.peaks).Count),
  ("session    : {0}" -f $st.sessionId),
  ("cause      : {0}" -f $st.lastCause),
  ("malice     : {0}" -f [int]$st.maliceCount),
  ("boundary   : {0}" -f [int]$st.boundaryCount),
  ("pact       : {0}" -f $(if ($st.pactPending) { 'waiting' } else { 'no' })),
  ("pactBroken : {0}" -f [int]$st.pactBrokenCount),
  ("lockCount  : {0}" -f [int]$st.lockCount)
)
$out = ($lines -join "`r`n")
Write-Output $out
if ($Json) { Write-Output ($st | ConvertTo-Json -Depth 8) }
