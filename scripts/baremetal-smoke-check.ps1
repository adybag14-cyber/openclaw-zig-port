$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-ZigExecutable {
    $defaultWindowsZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
    if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) {
        if (-not (Test-Path $env:OPENCLAW_ZIG_BIN)) {
            throw "OPENCLAW_ZIG_BIN is set but not found: $($env:OPENCLAW_ZIG_BIN)"
        }
        return $env:OPENCLAW_ZIG_BIN
    }

    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($null -ne $zigCmd -and $zigCmd.Path) {
        return $zigCmd.Path
    }

    if (Test-Path $defaultWindowsZig) {
        return $defaultWindowsZig
    }

    throw "Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure `zig` is on PATH."
}

Set-Location $repo
$zig = Resolve-ZigExecutable

& $zig build baremetal --summary all
if ($LASTEXITCODE -ne 0) {
    throw "zig build baremetal failed with exit code $LASTEXITCODE"
}

$candidates = @(
    (Join-Path $repo "zig-out\openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out/openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out\bin\openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out/bin/openclaw-zig-baremetal.elf")
)

$artifact = $null
foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
        $artifact = (Resolve-Path $candidate).Path
        break
    }
}

if ($null -eq $artifact) {
    throw "bare-metal artifact not found in expected zig-out paths."
}

$info = Get-Item $artifact
if ($info.Length -le 0) {
    throw "bare-metal artifact is empty: $artifact"
}

function Find-BytePattern {
    param(
        [byte[]] $Bytes,
        [byte[]] $Pattern
    )
    if ($Pattern.Length -eq 0 -or $Bytes.Length -lt $Pattern.Length) {
        return $false
    }
    for ($i = 0; $i -le ($Bytes.Length - $Pattern.Length); $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Pattern[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $true
        }
    }
    return $false
}

$bytes = [System.IO.File]::ReadAllBytes($artifact)
if ($bytes.Length -lt 4 -or $bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
    throw "artifact is not an ELF binary: $artifact"
}

# Multiboot2 magic in little-endian
$multiboot2Magic = [byte[]] @(0xD6, 0x50, 0x52, 0xE8)
$hasMultiboot2 = Find-BytePattern -Bytes $bytes -Pattern $multiboot2Magic
if (-not $hasMultiboot2) {
    throw "multiboot2 header magic not found in bare-metal artifact"
}

Write-Output "BAREMETAL_BUILD_HTTP=200"
Write-Output "BAREMETAL_ARTIFACT=$artifact"
Write-Output "BAREMETAL_SIZE_BYTES=$($info.Length)"
Write-Output "BAREMETAL_ELF_MAGIC_PRESENT=True"
Write-Output "BAREMETAL_MULTIBOOT2_MAGIC_PRESENT=True"
