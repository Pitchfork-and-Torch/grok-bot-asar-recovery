# Temp-file checks for the asar header reader and the restore guard.
# Does not read or write the installed Grok Bot folder.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'AsarHeader.ps1')
$restore = Join-Path $here 'Restore-GrokBotAsar.ps1'

function New-FakeAsar {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Json
    )
    $jsonBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $stringLength = $jsonBytes.Length
    $pad = (4 - ($stringLength % 4)) % 4
    $payloadSize = 4 + $stringLength + $pad
    $headerPickleSize = 4 + $payloadSize
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]4)
    $bw.Write([uint32]$headerPickleSize)
    $bw.Write([uint32]$payloadSize)
    $bw.Write([uint32]$stringLength)
    $bw.Write($jsonBytes)
    if ($pad -gt 0) {
        $bw.Write((New-Object byte[] $pad))
    }
    $bw.Write([byte]0)
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $bw.Dispose()
    $ms.Dispose()
}

$healthyJson = '{"files":{"dist":{"files":{"deps":{"files":{"tree-sitter":{"files":{"package.json":{"size":1757,"unpacked":true}}}}}}}}}'
$brokenJson = '{"files":{"dist":{"files":{"deps":{"files":{"tree-sitter":{"files":{}}}}}}}}'

function Invoke-RestoreCase {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $restore @ArgumentList 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $output }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) ("asar-recovery-test-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path (Join-Path $root 'resources') | Out-Null
$resources = Join-Path $root 'resources'
$failures = 0

function Assert-True {
    param([bool]$Condition, [string]$Name)
    if ($Condition) {
        Write-Host "PASS $Name"
    }
    else {
        Write-Host "FAIL $Name"
        $script:failures++
    }
}

try {
    $direct = Join-Path $resources 'direct-healthy.asar'
    New-FakeAsar -Path $direct -Json $healthyJson
    Assert-True (Test-AsarTreeSitterIndex -Path $direct) 'healthy header reads as healthy'

    $directBroken = Join-Path $resources 'direct-broken.asar'
    New-FakeAsar -Path $directBroken -Json $brokenJson
    Assert-True (-not (Test-AsarTreeSitterIndex -Path $directBroken)) 'empty stub reads as missing'

    $current = Join-Path $resources 'app.asar'
    New-FakeAsar -Path $current -Json $healthyJson
    $badBak = Join-Path $resources 'app.asar.bak-old'
    New-FakeAsar -Path $badBak -Json $brokenJson
    $hugeBroken = Join-Path $resources 'app.asar.broken-before-restore-old'
    [System.IO.File]::WriteAllBytes($hugeBroken, (New-Object byte[] 2000000))
    $before = [System.IO.File]::ReadAllBytes($current)
    $leave = Invoke-RestoreCase -ArgumentList @('-InstallRoot', $root, '-SkipStop', '-SkipLaunch')
    $after = [System.IO.File]::ReadAllBytes($current)
    Assert-True ($leave.Code -eq 0) 'healthy current exits 0'
    Assert-True ($leave.Out -match 'No restore') 'healthy current says no restore'
    Assert-True (([System.BitConverter]::ToString($before)) -eq ([System.BitConverter]::ToString($after))) 'healthy current bytes stay'

    $namesBeforeCheck = @(Get-ChildItem -LiteralPath $resources -File | ForEach-Object { $_.Name })
    $check = Invoke-RestoreCase -ArgumentList @('-InstallRoot', $root, '-CheckOnly')
    $namesAfterCheck = @(Get-ChildItem -LiteralPath $resources -File | ForEach-Object { $_.Name })
    Assert-True ($check.Code -eq 0) 'check-only healthy exits 0'
    Assert-True (($namesBeforeCheck -join ',') -eq ($namesAfterCheck -join ',')) 'check-only writes no backup'

    Remove-Item -LiteralPath $current -Force
    New-FakeAsar -Path $current -Json $brokenJson
    $checkBroken = Invoke-RestoreCase -ArgumentList @('-InstallRoot', $root, '-CheckOnly')
    Assert-True ($checkBroken.Code -eq 2) 'check-only broken exits 2'
    $onlyBroken = Invoke-RestoreCase -ArgumentList @('-InstallRoot', $root, '-SkipStop', '-SkipLaunch')
    Assert-True ($onlyBroken.Code -eq 2) 'broken backup is refused'
    Assert-True (-not (Test-AsarTreeSitterIndex -Path $current)) 'refused restore leaves the broken current file'

    $namesBeforeRestore = @(Get-ChildItem -LiteralPath $resources -File | ForEach-Object { $_.Name })
    $goodBak = Join-Path $resources 'app.asar.bak-good'
    New-FakeAsar -Path $goodBak -Json $healthyJson
    $restored = Invoke-RestoreCase -ArgumentList @('-InstallRoot', $root, '-SkipStop', '-SkipLaunch')
    Assert-True ($restored.Code -eq 0) 'healthy backup restores'
    Assert-True ($restored.Out -match 'app.asar.bak-good') 'chosen backup is the healthy bak'
    Assert-True (Test-AsarTreeSitterIndex -Path $current) 'restored file is healthy'
    $namesAfterRestore = @(Get-ChildItem -LiteralPath $resources -File | ForEach-Object { $_.Name })
    $added = @($namesAfterRestore | Where-Object { $namesBeforeRestore -notcontains $_ -and $_ -ne 'app.asar.bak-good' })
    Assert-True ($added.Count -ge 1 -and ($added -join ' ') -match 'broken-before-restore') 'previous file kept under a broken-before-restore name'

    $picked = Select-HealthyAsarBackup -ResourcesDir $resources -CurrentAsar $current
    Assert-True ($picked.Name -eq 'app.asar.bak-good') 'selector skips broken names and empty stubs'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

if ($failures -gt 0) {
    Write-Host "FAILED $failures"
    exit 1
}
Write-Host 'ALL PASS'
exit 0
