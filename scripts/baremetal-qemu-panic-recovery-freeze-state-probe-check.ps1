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
    Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_FREEZE_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-recovery probe failed with exit code $probeExitCode"
}

$panicMode = Extract-IntValue -Text $probeText -Name 'PANIC_MODE'
$panicCount = Extract-IntValue -Text $probeText -Name 'PANIC_COUNT'
$panicBootPhase = Extract-IntValue -Text $probeText -Name 'PANIC_BOOT_PHASE'
$panicRunningSlot = Extract-IntValue -Text $probeText -Name 'PANIC_RUNNING_SLOT'
$panicDispatchCount = Extract-IntValue -Text $probeText -Name 'PANIC_DISPATCH_COUNT'

if ($null -in @($panicMode, $panicCount, $panicBootPhase, $panicRunningSlot, $panicDispatchCount)) {
    throw 'Missing expected panic freeze-state fields in panic-recovery probe output.'
}
if ($panicMode -ne 255) { throw "Expected PANIC_MODE=255. got $panicMode" }
if ($panicCount -ne 1) { throw "Expected PANIC_COUNT=1. got $panicCount" }
if ($panicBootPhase -ne 255) { throw "Expected PANIC_BOOT_PHASE=255. got $panicBootPhase" }
if ($panicRunningSlot -ne 255) { throw "Expected PANIC_RUNNING_SLOT=255. got $panicRunningSlot" }
if ($panicDispatchCount -ne 1) { throw "Expected PANIC_DISPATCH_COUNT=1. got $panicDispatchCount" }

Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_FREEZE_STATE_PROBE=pass'
Write-Output "PANIC_MODE=$panicMode"
Write-Output "PANIC_COUNT=$panicCount"
Write-Output "PANIC_BOOT_PHASE=$panicBootPhase"
Write-Output "PANIC_RUNNING_SLOT=$panicRunningSlot"
Write-Output "PANIC_DISPATCH_COUNT=$panicDispatchCount"
