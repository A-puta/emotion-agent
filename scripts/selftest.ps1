$ErrorActionPreference = 'Stop'
$base = 'http://127.0.0.1:18100'
$results = @()

function Check($name, [scriptblock]$sb) {
  try {
    $r = & $sb
    $script:results += [pscustomobject]@{ 项目 = $name; 结果 = 'OK'; 说明 = "$r" }
  } catch {
    $script:results += [pscustomobject]@{ 项目 = $name; 结果 = 'FAIL'; 说明 = $_.Exception.Message }
  }
}

function GetJson($path) { (Invoke-WebRequest "$base$path" -UseBasicParsing -TimeoutSec 40).Content | ConvertFrom-Json }
function PostJson($path, $obj) {
  $b = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress -Depth 6))
  (Invoke-WebRequest "$base$path" -Method POST -Body $b -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 120).Content | ConvertFrom-Json
}

Check '状态读取' { $s = GetJson '/api/state'; "slots=$($s.emotion.slots.Count) anger=$($s.anger.anger)" }
Check '加情绪' { $r = GetJson '/api/emotion-set?label=%E5%BC%80%E5%BF%83'; $s = GetJson '/api/state'; "slots=" + (($s.emotion.slots | ForEach-Object { $_.label }) -join '+') }
Check '清空情绪' { GetJson '/api/emotion-clear' | Out-Null; $s = GetJson '/api/state'; "slots=$($s.emotion.slots.Count)" }
Check '怒气清零' { GetJson '/api/anger-reset' | Out-Null; $s = GetJson '/api/state'; "anger=$($s.anger.anger)" }
Check '切情绪模式' { PostJson '/api/emotion-mode?mode=all' @{} | Out-Null; $s = GetJson '/api/state'; "mode=$($s.emotionMode.mode)"; PostJson '/api/emotion-mode?mode=daily' @{} | Out-Null }
Check '切话语模式' { PostJson '/api/sentinel-mode?mode=model' @{} | Out-Null; $s = GetJson '/api/state'; "mode=$($s.sentinelMode.mode)"; PostJson '/api/sentinel-mode?mode=library' @{} | Out-Null }
Check '挑选一句' { $r = GetJson '/api/pick?fg=work'; $r.line }
Check '任务状态' { $r = GetJson '/api/tasks'; ($r.out -split "`n")[0] }

Check '部分权限拦截' {
  PostJson '/api/panel-mode' @{ mode = 'partial' } | Out-Null
  try { Invoke-WebRequest "$base/api/logs?name=sentinel" -UseBasicParsing -TimeoutSec 15 | Out-Null; throw '没有被拦' } catch { $code = [int]$_.Exception.Response.StatusCode; if ($code -ne 403) { throw "状态码 $code" }; "403 已拦" }
}
Check '完全权限放行' {
  PostJson '/api/panel-mode' @{ mode = 'full' } | Out-Null
  $r = GetJson '/api/logs?name=anger'
  "取到 $(([string]$r.out).Length) 字"
}

Check '工具:读状态' {
  $r = PostJson '/api/chat' @{ text = '现在情绪槽和怒气是多少，只报数值' }
  "trace=" + (($r.trace | ForEach-Object { $_.tool }) -join ',')
}
Check '工具:记与想' {
  PostJson '/api/chat' @{ text = '记住：周五要交板子' } | Out-Null
  $r = PostJson '/api/chat' @{ text = '你还记得我让你记什么了吗' }
  "trace=" + (($r.trace | ForEach-Object { $_.tool }) -join ',') + " | " + $r.reply.Substring(0, [Math]::Min(40, $r.reply.Length))
}
Check '工具:发文件' {
  $r = PostJson '/api/chat' @{ text = '把 README 发给我' }
  $u = ($r.trace | Where-Object { $_.tool -eq 'send_file' } | Select-Object -First 1).result.url
  "url=$u"
}
Check '工具:失败如实说' {
  $r = PostJson '/api/chat' @{ text = '把 D:\\根本没有这个.txt 发我' }
  $e = ($r.trace | Select-Object -First 1).result.error
  "err=$e | 回复=$($r.reply.Substring(0,[Math]::Min(30,$r.reply.Length)))"
}
Check '文件下载' {
  $f = Invoke-WebRequest "$base/files/README.md" -UseBasicParsing -TimeoutSec 20
  "HTTP $($f.StatusCode) $($f.RawContentLength) 字节"
}

# 副本一致性：scripts/ 与 plugin/assets/ 里的同名脚本必须一致
Check '副本一致性' {
  $root = Split-Path -Parent $PSScriptRoot
  $a = Join-Path $root 'scripts'
  $b = Join-Path $root 'plugin\assets'
  $diff = @()
  foreach ($f in Get-ChildItem $a -File) {
    $other = Join-Path $b $f.Name
    if ((Test-Path $other) -and ((Get-FileHash $f.FullName).Hash -ne (Get-FileHash $other).Hash)) { $diff += $f.Name }
  }
  if ($diff.Count) { throw ("不一致：" + ($diff -join ', ')) }
  "一致"
}

$results | Format-Table -AutoSize | Out-String -Width 150
$fail = ($results | Where-Object { $_.结果 -ne 'OK' }).Count
"失败项：$fail / $($results.Count)"
