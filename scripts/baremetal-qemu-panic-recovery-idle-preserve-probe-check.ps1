param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-panic-recovery-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_PANIC_RECOVERY_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_IDLE_PRESERVE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-recovery probe failed with exit code $probeExitCode"
}

$idleTicks = Extract-IntValue -Text $probeText -Name 'IDLE_PANIC_TICKS'
$idleDispatchCount = Extract-IntValue -Text $probeText -Name 'IDLE_PANIC_DISPATCH_COUNT'
$idleRunCount = Extract-IntValue -Text $probeText -Name 'IDLE_PANIC_RUN_COUNT'

if ($null -in @($idleTicks, $idleDispatchCount, $idleRunCount)) {
    throw 'Missing expected idle panic fields in panic-recovery probe output.'
}
if ($idleTicks -lt 1) { throw "Expected IDLE_PANIC_TICKS>=1. got $idleTicks" }
if ($idleDispatchCount -ne 1) { throw "Expected IDLE_PANIC_DISPATCH_COUNT=1. got $idleDispatchCount" }
if ($idleRunCount -ne 1) { throw "Expected IDLE_PANIC_RUN_COUNT=1. got $idleRunCount" }

Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_IDLE_PRESERVE_PROBE=pass'
Write-Output "IDLE_PANIC_TICKS=$idleTicks"
Write-Output "IDLE_PANIC_DISPATCH_COUNT=$idleDispatchCount"
Write-Output "IDLE_PANIC_RUN_COUNT=$idleRunCount"
