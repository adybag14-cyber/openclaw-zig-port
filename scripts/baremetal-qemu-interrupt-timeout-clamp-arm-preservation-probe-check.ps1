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
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARM_PRESERVATION_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout clamp probe failed with exit code $probeExitCode"
}

$armTicks = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARM_TICKS'
$armedWaitTimeout = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARMED_WAIT_TIMEOUT'

if ($null -in @($armTicks, $armedWaitTimeout)) {
    throw 'Missing expected arm-preservation fields in interrupt-timeout clamp probe output.'
}
if ($armTicks -ne [UInt64]::MaxValue) { throw "Expected ARM_TICKS=$([UInt64]::MaxValue). got $armTicks" }
if ($armedWaitTimeout -ne $armTicks) { throw "Expected ARMED_WAIT_TIMEOUT to equal ARM_TICKS. got $armedWaitTimeout vs $armTicks" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARM_PRESERVATION_PROBE=pass'
Write-Output "ARM_TICKS=$armTicks"
Write-Output "ARMED_WAIT_TIMEOUT=$armedWaitTimeout"
