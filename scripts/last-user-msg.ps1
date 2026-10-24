param([string]$SessionsRoot)
# Prints epoch ms of the user's last real message in the QQ/IM session tree, or "none".
# Exit 2 when node cannot be found (never silently fall back to another runtime).
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$cfg = $null
try { $cfg = ([IO.File]::ReadAllText((Join-Path $root 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { }
$node = 'D:\Node\node.exe'
if ($cfg -and $cfg.nodeExe) { $node = [string]$cfg.nodeExe }
if (-not (Test-Path -LiteralPath $node)) {
  [Console]::Error.WriteLine("node not found: $node")
  Write-Output 'none'
  exit 2
}

$sess = if ($SessionsRoot) { $SessionsRoot } else { Join-Path $env:USERPROFILE '.dsh\sessions' }
$im = Get-ChildItem -LiteralPath $sess -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like '*dsh-im*' } | Select-Object -First 1
$scan = if ($im) { $im.FullName } else { $sess }

$out = & $node (Join-Path $root 'last-user-msg.mjs') $scan 5 2>$null
$out = ([string]$out).Trim()
if ($out -match '^\d+$') { Write-Output $out } else { Write-Output 'none' }
