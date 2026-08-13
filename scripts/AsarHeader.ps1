# Reads an Electron asar header and reports whether tree-sitter is a real file.
# A healthy index has dist/deps/tree-sitter/package.json with size greater than 0.
# An empty directory stub has no size and is not healthy.

Set-StrictMode -Version Latest

function Read-AsarHeaderObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        $pre = New-Object byte[] 16
        $got = $stream.Read($pre, 0, 16)
        if ($got -ne 16) {
            throw "asar header is shorter than 16 bytes: $Path"
        }
        $picklePayload = [BitConverter]::ToUInt32($pre, 0)
        if ($picklePayload -ne 4) {
            throw "asar size pickle is not 4 bytes: $Path"
        }
        $stringLength = [BitConverter]::ToUInt32($pre, 12)
        if ($stringLength -lt 2 -or $stringLength -gt 32MB) {
            throw "asar header string length is out of range: $Path"
        }
        $jsonBytes = New-Object byte[] $stringLength
        $filled = 0
        while ($filled -lt $stringLength) {
            $n = $stream.Read($jsonBytes, $filled, $stringLength - $filled)
            if ($n -le 0) {
                throw "asar header ended before the JSON: $Path"
            }
            $filled += $n
        }
        $json = [System.Text.Encoding]::UTF8.GetString($jsonBytes)
        return ($json | ConvertFrom-Json)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-AsarChild {
    param($Node, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Node -or $null -eq $Node.files) {
        return $null
    }
    $prop = $Node.files.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }
    return $prop.Value
}

function Test-AsarTreeSitterIndex {
    param([Parameter(Mandatory = $true)][string]$Path)
    $header = Read-AsarHeaderObject -Path $Path
    $dist = Get-AsarChild -Node $header -Name 'dist'
    $deps = Get-AsarChild -Node $dist -Name 'deps'
    $pkgDir = Get-AsarChild -Node $deps -Name 'tree-sitter'
    $packageJson = Get-AsarChild -Node $pkgDir -Name 'package.json'
    if ($null -eq $packageJson) {
        return $false
    }
    $sizeProp = $packageJson.PSObject.Properties['size']
    if ($null -eq $sizeProp) {
        return $false
    }
    return ([int64]$sizeProp.Value -gt 0)
}

function Select-HealthyAsarBackup {
    param(
        [Parameter(Mandatory = $true)][string]$ResourcesDir,
        [Parameter(Mandatory = $true)][string]$CurrentAsar
    )

    $named = @(Get-ChildItem -LiteralPath $ResourcesDir -Filter 'app.asar.bak*' -File -ErrorAction SilentlyContinue)
    $others = @(Get-ChildItem -LiteralPath $ResourcesDir -Filter 'app.asar.*' -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -ne 'app.asar' -and
            $_.Name -notlike 'app.asar.bak*' -and
            $_.Name -notmatch 'broken'
        })
    $ordered = @($named + $others | Sort-Object LastWriteTime -Descending)
    foreach ($file in $ordered) {
        if ($file.FullName -eq $CurrentAsar) {
            continue
        }
        if ($file.Name -match 'broken') {
            continue
        }
        if (Test-AsarTreeSitterIndex -Path $file.FullName) {
            return $file
        }
    }
    return $null
}
