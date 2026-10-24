# Integrity check for the sentinel/anger scripts.
# ASCII-only. It hashes every .ps1 / .json / .vbs in this folder and compares with baseline-hashes.txt.
# Usage:  check-hashes.ps1            -> compare
#         check-hashes.ps1 -Update    -> (re)write the baseline after a deliberate change

param([switch]$Update)

$ErrorActionPreference = 'Stop'
$root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$baseName = 'baseline-hashes.txt'
$basePath = Join-Path $root $baseName
$report   = Join-Path $root 'hash-report.txt'
$exts     = @('.ps1', '.json', '.vbs')

$files = Get-ChildItem -LiteralPath $root -File |
         Where-Object { $exts -contains $_.Extension.ToLower() -and $_.Name -ne $baseName } |
         Sort-Object Name

if ($Update) {
  $lines = @()
  foreach ($f in $files) { $lines += ("{0}  {1}" -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash, $f.Name) }
  [IO.File]::WriteAllText($basePath, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))
  Write-Output ("baseline written: {0} file(s) -> {1}" -f @($lines).Count, $baseName)
  exit 0
}

if (-not (Test-Path -LiteralPath $basePath)) { Write-Output ('no baseline: run with -Update first'); exit 1 }
$base = @{}
foreach ($l in ([IO.File]::ReadAllLines($basePath, [Text.Encoding]::UTF8))) {
  if ($l -match '^([0-9A-Fa-f]{64})\s\s(.+)$') { $base[$Matches[2]] = $Matches[1].ToUpper() }
}

$rows = @()
$bad = 0
foreach ($f in $files) {
  $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToUpper()
  if (-not $base.ContainsKey($f.Name)) { $rows += ("NEW      {0}" -f $f.Name); $bad++ }
  elseif ($base[$f.Name] -ne $h) { $rows += ("CHANGED  {0}" -f $f.Name); $bad++ }
  else { $rows += ("ok       {0}" -f $f.Name) }
}
foreach ($n in $base.Keys) {
  $still = $false
  foreach ($f in $files) { if ($f.Name -eq $n) { $still = $true } }
  if (-not $still) { $rows += ("GONE     {0}" -f $n); $bad++ }
}

$rows += ("RESULT   {0} file(s) differ from baseline" -f $bad)
$out = ($rows -join "`r`n")
Write-Output $out
if ($bad -gt 0) { exit 1 }
