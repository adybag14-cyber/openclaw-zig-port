param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-clamp-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Extract-UIntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [UInt64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_SATURATED_BOUNDARY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout clamp probe failed with exit code $probeExitCode"
}

$ticks = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TICKS'
$wakeTicks = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE_TICKS'
$waitKind0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAIT_KIND0'
$waitVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAIT_VECTOR0'
$waitTimeout0 = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAIT_TIMEOUT0'

if ($null -in @($ticks, $wakeTicks, $waitKind0, $waitVector0, $waitTimeout0)) {
    throw 'Missing expected saturated-boundary fields in interrupt-timeout clamp probe output.'
}
if ($ticks -ne 0) { throw "Expected TICKS=0. got $ticks" }
if ($wakeTicks -ne 0) { throw "Expected WAKE_TICKS=0. got $wakeTicks" }
if ($waitKind0 -ne 0) { throw "Expected WAIT_KIND0=0. got $waitKind0" }
if ($waitVector0 -ne 0) { throw "Expected WAIT_VECTOR0=0. got $waitVector0" }
if ($waitTimeout0 -ne 0) { throw "Expected WAIT_TIMEOUT0=0. got $waitTimeout0" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_SATURATED_BOUNDARY_PROBE=pass'
Write-Output "TICKS=$ticks"
Write-Output "WAKE_TICKS=$wakeTicks"
Write-Output "WAIT_KIND0=$waitKind0"
Write-Output "WAIT_VECTOR0=$waitVector0"
Write-Output "WAIT_TIMEOUT0=$waitTimeout0"
