<#
.SYNOPSIS
  Recover Grok Bot desktop when main process fails with "Cannot find module 'tree-sitter'".

.DESCRIPTION
  A common cause is a corrupted app.asar where dist/deps entries are empty stubs
  while real native packages still live under app.asar.unpacked.

  v1.1.0 reads the asar header first.
  A healthy archive already lists dist/deps/tree-sitter/package.json with a size.
  The script leaves that file alone.
  A backup is used only when its header is also healthy.
  Files with "broken" in the name are never chosen.

.PARAMETER InstallRoot
  Grok Bot install root. Default: %LOCALAPPDATA%\Programs\Grok Bot

.PARAMETER SkipStop
  Do not stop running processes.

.PARAMETER SkipLaunch
  Do not start Grok Bot.exe after a restore.

.PARAMETER CheckOnly
  Print the header check and exit. Exit 0 when healthy, exit 2 when not. No copies.

.PARAMETER Force
  Restore even when the current app.asar is already healthy.
  Still refuses a backup whose header is missing tree-sitter.

.PARAMETER WhatIf
  Show actions without changing files.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Restore-GrokBotAsar.ps1 -CheckOnly
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Grok Bot'),
    [switch]$SkipStop,
    [switch]$SkipLaunch,
    [switch]$CheckOnly,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'AsarHeader.ps1')

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

$treeSitterPkg = Join-Path $unpackedDeps 'tree-sitter\package.json'
$treeSitterNode = Join-Path $unpackedDeps 'tree-sitter\build\Release\tree_sitter_runtime_binding.node'
Write-Step "unpacked tree-sitter package.json present: $(Test-Path -LiteralPath $treeSitterPkg)"
Write-Step "unpacked tree-sitter .node present: $(Test-Path -LiteralPath $treeSitterNode)"

$healthy = Test-AsarTreeSitterIndex -Path $asar
Write-Step "current app.asar tree-sitter index: $(if ($healthy) { 'healthy' } else { 'missing' })"

if ($CheckOnly) {
    if ($healthy) { exit 0 }
    exit 2
}

if ($healthy -and -not $Force) {
    Write-Step "app.asar already lists tree-sitter/package.json. No restore."
    exit 0
}

$chosen = Select-HealthyAsarBackup -ResourcesDir $resources -CurrentAsar $asar
if ($null -eq $chosen) {
    Write-Step "No healthy app.asar backup. A file named broken, or a backup that is also missing tree-sitter, is not used. Reinstall Grok Bot from the official installer."
    exit 2
}

Write-Step "Chosen backup: $($chosen.Name) ($([math]::Round($chosen.Length/1MB, 1)) MB)"

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

if (-not (Test-AsarTreeSitterIndex -Path $asar)) {
    Write-Step "Restored header is still missing tree-sitter. Putting the previous app.asar back."
    if ((Test-Path -LiteralPath $brokenCopy) -and $PSCmdlet.ShouldProcess($brokenCopy, "Copy back to $asar")) {
        Copy-Item -LiteralPath $brokenCopy -Destination $asar -Force
    }
    exit 2
}

$after = Get-Item -LiteralPath $asar
Write-Step "Restored app.asar size=$($after.Length) LastWriteTime=$($after.LastWriteTime)"

if ($SkipLaunch) {
    Write-Step "SkipLaunch set. Start Grok Bot yourself when you are ready."
}
elseif (Test-Path -LiteralPath $exe) {
    Write-Step "Launch: $exe"
    if ($PSCmdlet.ShouldProcess($exe, 'Start-Process')) {
        Start-Process -FilePath $exe | Out-Null
    }
}
else {
    Write-Step "Executable not found at expected path. Start Grok Bot manually."
}

Write-Step "Done."
