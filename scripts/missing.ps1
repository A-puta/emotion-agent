<#
  missing.ps1 — 思念值状态管理器（与 anger.ps1 平行）
  等级：C（低） -> B -> A（高）；状态存 结衣状态\missing.json

  用法：
    -Show                     只读打印当前状态
    -Decide                   由哨兵调用一次"投掷/判定"，输出 action=send|skip 与 level（JSON）
    -MarkSent  -Tag <标签>     哨兵真正发出后回报；记录 lastSentAt / lastTag
    -Reset                    等级降回 C（结衣判定"已产生完整对话"时用）
    -StatePath <路径>          覆盖状态文件路径（默认 结衣状态\missing.json）
    -SessionsRoot <路径>       覆盖会话目录（默认 ~\.dsh\sessions）

  判定依据（用户指定）：
    - 上一次哨兵发送之后、本次判定之前，会话文件有更新 => 用户回复过 => 视为已形成对话 => 等级降回 C
    - C 级：40% 概率"没能升到 B"（羞怯条例1），60% 升到 B
    - B 级：60% 概率输出 <思念>；40% 不输出并计入 shyStreak，连续 2 次 => 直接升 A
    - A 级：每次判定都输出 <思念>；一旦用户回复形成完整对话 => 降到 C
#>
[CmdletBinding()]
param(
  [switch]$Show,
  [switch]$Decide,
  [switch]$MarkSent,
  [switch]$Reset,
  [string]$Tag,
  [string]$StatePath,
  [string]$SessionsRoot
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Load-Cfg {
  $p = Join-Path $root 'config.json'
  if (-not (Test-Path $p)) { return $null }
  return ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Resolve-StatePath {
  if ($StatePath) { return $StatePath }
  return (Join-Path (Split-Path $root -Parent) '结衣状态\missing.json')
}
function Read-Json([string]$p) {
  if (-not (Test-Path $p)) { return $null }
  try { return ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}
function Write-Json([string]$p, $obj) {
  $dir = Split-Path $p -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $json = $obj | ConvertTo-Json -Depth 6
  [IO.File]::WriteAllText($p, $json, (New-Object Text.UTF8Encoding($false)))
}
function Roll-Below([int]$percent) {
  # 返回 $true 表示"命中该百分比"
  return ((Get-Random -Minimum 0 -Maximum 100) -lt $percent)
}

$cfg = Load-Cfg
$sp  = Resolve-StatePath

# 默认值（config 缺项时兜底）
$defLevel = 'C'
$upProb = 60            # C -> B 的成功概率
$outProb = 60           # B 级输出 <思念> 的概率
$shyMax = 2             # 连续多少次未输出即直升 A
$aStop = 5              # A 级连着发满多少条没被回应就转成"被晾着"
$sessRoot = if ($SessionsRoot) { $SessionsRoot } else { Join-Path $env:USERPROFILE '.dsh\sessions' }
$minSilenceH = 1
if ($cfg) {
  if ($cfg.limits -and $cfg.limits.minSilenceHours) { $minSilenceH = [int]$cfg.limits.minSilenceHours }
  $ms = $null
  if ($cfg.missing -and $cfg.missing.rules -and $cfg.missing.rules.missingValue) { $ms = $cfg.missing.rules.missingValue }
  if ($ms) {
    if ($ms.defaultLevel) { $defLevel = [string]$ms.defaultLevel }
    if ($ms.upgradeProbability) { $upProb = [int]$ms.upgradeProbability }
    if ($ms.outputProbability) { $outProb = [int]$ms.outputProbability }
    if ($ms.shyStreakToA) { $shyMax = [int]$ms.shyStreakToA }
    if ($ms.aStopAfter) { $aStop = [int]$ms.aStopAfter }
  }
}
if ($defLevel -notin @('C','B','A')) { $defLevel = 'C' }

$st = Read-Json $sp
if (-not $st) {
  $st = [pscustomobject]@{ sessionId = $null; level = $defLevel; shyStreak = 0; lastSentAt = $null; lastTag = $null; aSent = 0; neglect = $false; causes = @(); ignoredCount = 0; answeredCount = 0; lastCause = ''; updatedAt = (Get-Date).ToString('s') }
}
foreach ($f in 'sessionId','level','shyStreak','lastSentAt','lastTag','aSent','neglect','causes','ignoredCount','answeredCount','lastCause','updatedAt') {
  if (-not (@($st.PSObject.Properties.Name) -contains $f)) { $st | Add-Member -NotePropertyName $f -NotePropertyValue $null }
}
if (-not $st.level -or ($st.level -notin @('C','B','A'))) { $st.level = $defLevel }
$st.shyStreak = [int]$st.shyStreak
$st.aSent = [int]$st.aSent

# 会话归属：只认 QQ / IM 渠道的会话目录（用户指定：是否回复只看 QQ，别的会话不管）。
# 目录名只跟渠道有关，所以别的会话再活跃也不会把状态和 lastTag 重置掉。
$imDir = $null
try {
  $imDir = Get-ChildItem -LiteralPath $sessRoot -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like '*dsh-im*' } | Select-Object -First 1
} catch { }
$curSess = if ($imDir) { $imDir.Name } else { 'unknown' }

# ---- 沉默时长：从用户最后一句话算起（用户指定 2026-10-18）----
# 只看 QQ/IM 会话里"真人发来的消息"，不像旧判据那样把结衣自己的回复也算成用户说话。
$lastUserMs = 0
try {
  $luOut = & (Join-Path $root 'last-user-msg.ps1') 2>$null | Out-String
  if ($luOut -and $luOut.Trim() -match '^\d+$') { $lastUserMs = [long]$luOut.Trim() }
} catch { $lastUserMs = 0 }
$silenceMin = -1
if ($lastUserMs -gt 0) {
  $silenceMin = ((Get-Date) - ([DateTimeOffset]::FromUnixTimeMilliseconds($lastUserMs).LocalDateTime)).TotalMinutes
}
$silenceGateMin = $minSilenceH * 60

# 会话 id 不一致 => 按默认等级重新开始
if ($st.sessionId -ne $curSess) {
  $st.sessionId = $curSess
  $st.level = $defLevel
  $st.shyStreak = 0
  $st.lastSentAt = $null
  $st.lastTag = $null
  $st.aSent = 0
  $st.neglect = $false
  $st.causes = @()
  $st.ignoredCount = 0
  $st.answeredCount = 0
  $st.lastCause = ''
}

# 原因标签：ignored = 多次思念没被回应，answered = 终于被回应。
# 两类分开计数、分开留痕；只留最近 20 条。
function Push-Cause([string]$tag) {
  $label = switch ($tag) {
    'ignored'  { '多次思念未获回应' }
    'answered' { '思念终于被回应' }
    default    { '其它' }
  }
  $rec = [pscustomobject]@{ tag = $tag; label = $label; at = (Get-Date).ToString('s'); level = $st.level; aSent = [int]$st.aSent }
  $list = @($st.causes) + @($rec)
  if ($list.Count -gt 20) { $list = $list[($list.Count - 20)..($list.Count - 1)] }
  $st.causes = $list
  $st.lastCause = $tag
}

function Save-State {
  $st.updatedAt = (Get-Date).ToString('s')
  Write-Json $sp $st
}

if ($Show) {
  [pscustomobject]@{
    action    = 'show'
    level     = $st.level
    shyStreak = $st.shyStreak
    aSent     = $st.aSent
    neglect   = [bool]$st.neglect
    lastSent  = $(if ($st.lastSentAt) { ([datetime]$st.lastSentAt).ToString('MM-dd HH:mm') } else { '-' })
    lastTag   = $(if ($st.lastTag) { $st.lastTag } else { '-' })
    cause     = $(if ($st.lastCause) { $st.lastCause } else { '-' })
    ignored   = [int]$st.ignoredCount
    answered  = [int]$st.answeredCount
    session   = $st.sessionId
    updatedAt = $st.updatedAt
  } | ConvertTo-Json -Compress
  exit 0
}

if ($Reset) {
  $old = $st.level
  $st.level = 'C'
  $st.shyStreak = 0
  $st.aSent = 0
  $st.neglect = $false
  $st.causes = @()
  $st.ignoredCount = 0
  $st.answeredCount = 0
  $st.lastCause = ''
  Save-State
  [pscustomobject]@{ action = 'reset'; from = $old; level = $st.level } | ConvertTo-Json -Compress
  exit 0
}

if ($MarkSent) {
  $st.lastSentAt = (Get-Date).ToString('s')
  if ($Tag) { $st.lastTag = $Tag }
  # A 级每成功发出一条思念就记一笔；连着发满 aStop 条还没被回应 -> 转成"被晾着"。
  # 注意：哨兵回报的标签是等级规则名（思念A / 思念B / 思念C），所以按前缀认，别按全等。
  if ($st.level -eq 'A' -and $Tag -and ([string]$Tag).StartsWith('思念')) {
    $st.aSent = [int]$st.aSent + 1
    if ($st.aSent -ge $aStop) {
      $st.neglect = $true
      $st.ignoredCount = [int]$st.ignoredCount + 1
      Push-Cause 'ignored'
    }
  }
  Save-State
  [pscustomobject]@{ action = 'mark-sent'; level = $st.level; tag = $st.lastTag; aSent = $st.aSent; neglect = [bool]$st.neglect } | ConvertTo-Json -Compress
  exit 0
}

if ($Decide) {
  # ---- 是否已经产生过对话（上次发送之后会话文件有写入）----
  # 沉默满 minSilenceH 小时 = "已经聊完、可以开始投掷"；不满 = 还在一起说话，这轮不投。
  $replied = $false
  if ($silenceMin -ge 0) {
    $replied = ($silenceMin -lt $silenceGateMin)
  } else {
    # 兜底：拿不到最后一句话时退回旧判据（宁可少发，不乱发）
    $newest = $null
    try {
      $scanRoot = if ($imDir) { $imDir.FullName } else { $sessRoot }
      $newest = Get-ChildItem -LiteralPath $scanRoot -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
    } catch { }
    if ($newest) {
      $silenceMin = ((Get-Date) - $newest.LastWriteTime).TotalMinutes
      if ($st.lastSentAt) { $replied = ([datetime]$newest.LastWriteTime -gt [datetime]$st.lastSentAt) }
    }
  }

  $oldLevel = $st.level
  $send = $true
  $reason = ''

  if ($st.level -eq 'A') {
    if ($replied) {
      # 你回来了：等级回 C，被晾清空（那份气由 anger.ps1 的 -Comfort 单独消）
      if ($st.lastCause -eq 'ignored') {
        $st.answeredCount = [int]$st.answeredCount + 1
        Push-Cause 'answered'
      }
      $st.level = 'C'; $st.shyStreak = 0; $st.aSent = 0; $st.neglect = $false
      $reason = 'complete-dialogue->C'
      $send = $false
    }
    elseif ($st.neglect) {
      # 已经转成"被晾着"：停发思念，等你回来
      $reason = "A(neglect, sent=$($st.aSent))->stop"
      $send = $false
    }
    else {
      $reason = 'A->hourly-missing'
    }
  }
  elseif ($st.level -eq 'B') {
    if ($replied) {
      $st.level = 'C'; $st.shyStreak = 0; $st.aSent = 0; $st.neglect = $false
      $reason = 'replied->C'
      $send = $false
    } elseif (Roll-Below $outProb) {
      $reason = 'B->missing-output'
    } else {
      $st.shyStreak = [int]$st.shyStreak + 1
      $reason = "B->shy($($st.shyStreak)/$shyMax)"
      if ($st.shyStreak -ge $shyMax) {
        $st.level = 'A'; $st.shyStreak = 0
        $reason = 'B->shy x2->A'
        $send = $true
      } else {
        $send = $false
      }
    }
  }
  else {
    # C（最低级）
    # 升级的唯一途径：上一次哨兵发出的是**日常话语**（淘气/关心/好奇），而用户没有回应。
    # 只按"没检测到回复"投掷是错的（用户指定修正）。
    $dailyTags = @('淘气', '关心', '好奇')
    $lastWasDaily = [bool]($st.lastTag -and ($dailyTags -contains [string]$st.lastTag))
    if ($replied) {
      $st.level = 'C'; $st.shyStreak = 0; $st.aSent = 0; $st.neglect = $false
      $reason = 'C(replied,no-upgrade)'
      $send = $false
    } elseif (-not $lastWasDaily) {
      $st.level = 'C'; $st.shyStreak = 0
      $reason = "C(wait-daily,lastTag=$($st.lastTag))"
      $send = $false
    } elseif (Roll-Below $upProb) {
      $st.level = 'B'
      $reason = "C->B(up$upProb%)"
    } else {
      $st.shyStreak = [int]$st.shyStreak + 1
      $reason = 'C->shy(no-upgrade)'
    }
  }

  Save-State
  [pscustomobject]@{
    action    = $(if ($send) { 'send' } else { 'skip' })
    fromLevel = $oldLevel
    level     = $st.level
    missing   = [bool]($st.level -eq 'A' -or ($st.level -eq 'B' -and $reason -like 'B->missing*'))
    replied   = $replied
    silenceMin = $(if ($silenceMin -ge 0) { [math]::Round($silenceMin, 1) } else { -1 })
    shyStreak = $st.shyStreak
    aSent     = $st.aSent
    neglect   = [bool]$st.neglect
    cause     = $(if ($st.lastCause) { $st.lastCause } else { '-' })
    ignored   = [int]$st.ignoredCount
    answered  = [int]$st.answeredCount
    reason    = $reason
  } | ConvertTo-Json -Compress
  exit 0
}

# 无参数：等同 -Show
[pscustomobject]@{
  action = 'show'; level = $st.level; shyStreak = $st.shyStreak
  lastSent = $(if ($st.lastSentAt) { ([datetime]$st.lastSentAt).ToString('MM-dd HH:mm') } else { '-' })
  lastTag = $st.lastTag; session = $st.sessionId
} | ConvertTo-Json -Compress
