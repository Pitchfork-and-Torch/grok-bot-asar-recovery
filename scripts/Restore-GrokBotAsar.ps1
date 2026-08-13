<#
.SYNOPSIS
  Recover Grok Bot desktop when main process fails with "Cannot find module 'tree-sitter'".

.DESCRIPTION
  A common cause is a corrupted app.asar where dist/deps entries are empty stubs
  while real native packages still live under app.asar.unpacked.

  This script:
  1. Stops running Grok Bot processes (optional)
  2. Backs up the current app.asar
  3. Restores the newest matching app.asar.bak* if present
  4. Optionally verifies tree-sitter is loadable from app.asar.unpacked

.PARAMETER InstallRoot
  Grok Bot install root. Default: %LOCALAPPDATA%\Programs\Grok Bot

.PARAMETER SkipStop
  Do not stop running processes.

.PARAMETER WhatIf
  Show actions without changing files.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Restore-GrokBotAsar.ps1
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Grok Bot'),
    [switch]$SkipStop
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step([string]$Message) {
    Write-Host "[grok-bot-asar-recovery] $Message"
}

$resources = Join-Path $InstallRoot 'resources'
$asar = Join-Path $resources 'app.asar'
$unpackedDeps = Join-Path $resources 'app.asar.unpacked\dist\deps'
$exe = Join-Path $InstallRoot 'Grok Bot.exe'

if (-not (Test-Path -LiteralPath $InstallRoot)) {
    throw "Install root not found: $InstallRoot"
}
if (-not (Test-Path -LiteralPath $asar)) {
    throw "app.asar not found: $asar"
}

Write-Step "InstallRoot = $InstallRoot"

# --- diagnostics ---
$treeSitterPkg = Join-Path $unpackedDeps 'tree-sitter\package.json'
$treeSitterNode = Join-Path $unpackedDeps 'tree-sitter\build\Release\tree_sitter_runtime_binding.node'
Write-Step "unpacked tree-sitter package.json present: $(Test-Path -LiteralPath $treeSitterPkg)"
Write-Step "unpacked tree-sitter .node present: $(Test-Path -LiteralPath $treeSitterNode)"

$backups = @(Get-ChildItem -LiteralPath $resources -Filter 'app.asar.bak*' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending)
if ($backups.Count -eq 0) {
    # also accept common forensic names
    $backups = @(Get-ChildItem -LiteralPath $resources -Filter 'app.asar.*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'app.asar' -and $_.Length -gt 1MB } |
        Sort-Object Length -Descending)
}

if ($backups.Count -eq 0) {
    throw @"
No app.asar backup found under resources.
Look for a pre-patch file such as app.asar.bak-* next to app.asar, or reinstall Grok Bot.
Unpacked deps path (for support): $unpackedDeps
"@
}

$chosen = $backups | Select-Object -First 1
Write-Step "Chosen backup: $($chosen.Name) ($([math]::Round($chosen.Length/1MB,1)) MB)"

if (-not $SkipStop) {
    $procs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.ProcessName -eq 'Grok Bot' -or $_.ProcessName -like 'Grok*Bot*'
        })
    foreach ($p in $procs) {
        Write-Step "Stopping PID $($p.Id) ($($p.ProcessName))"
        if ($PSCmdlet.ShouldProcess("PID $($p.Id)", 'Stop-Process')) {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 1
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$brokenCopy = Join-Path $resources "app.asar.broken-before-restore-$stamp"
Write-Step "Backing up current asar -> $(Split-Path $brokenCopy -Leaf)"
if ($PSCmdlet.ShouldProcess($asar, "Copy to $brokenCopy")) {
    Copy-Item -LiteralPath $asar -Destination $brokenCopy -Force
}

Write-Step "Restoring $($chosen.Name) -> app.asar"
if ($PSCmdlet.ShouldProcess($chosen.FullName, "Copy to $asar")) {
    Copy-Item -LiteralPath $chosen.FullName -Destination $asar -Force
}

$after = Get-Item -LiteralPath $asar
Write-Step "Restored app.asar size=$($after.Length) LastWriteTime=$($after.LastWriteTime)"

if (Test-Path -LiteralPath $exe) {
    Write-Step "Launch: $exe"
    if ($PSCmdlet.ShouldProcess($exe, 'Start-Process')) {
        Start-Process -FilePath $exe | Out-Null
    }
} else {
    Write-Step "Executable not found at expected path; start Grok Bot manually."
}

Write-Step "Done. If the error returns, reinstall Grok Bot from the official installer."
