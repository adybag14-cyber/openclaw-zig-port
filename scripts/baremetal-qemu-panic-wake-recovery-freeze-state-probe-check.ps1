param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-panic-wake-recovery-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_FREEZE_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-wake recovery probe failed with exit code $probeExitCode"
}

$lastOpcode = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_LAST_RESULT'
$mode = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_MODE'
$bootPhase = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_BOOT_PHASE'
$panicCount = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_PANIC_COUNT'
$taskCount = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_RUNNING_SLOT'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'PANIC_FREEZE_DISPATCH_COUNT'

if ($null -in @($lastOpcode, $lastResult, $mode, $bootPhase, $panicCount, $taskCount, $runningSlot, $dispatchCount)) {
    throw 'Missing expected freeze-state fields in panic-wake recovery probe output.'
}
if ($lastOpcode -ne 5) { throw "Expected PANIC_FREEZE_LAST_OPCODE=5. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected PANIC_FREEZE_LAST_RESULT=0. got $lastResult" }
if ($mode -ne 255) { throw "Expected PANIC_FREEZE_MODE=255. got $mode" }
if ($bootPhase -ne 255) { throw "Expected PANIC_FREEZE_BOOT_PHASE=255. got $bootPhase" }
if ($panicCount -ne 1) { throw "Expected PANIC_FREEZE_PANIC_COUNT=1. got $panicCount" }
if ($taskCount -ne 0) { throw "Expected PANIC_FREEZE_TASK_COUNT=0. got $taskCount" }
if ($runningSlot -ne 255) { throw "Expected PANIC_FREEZE_RUNNING_SLOT=255. got $runningSlot" }
if ($dispatchCount -ne 0) { throw "Expected PANIC_FREEZE_DISPATCH_COUNT=0. got $dispatchCount" }

Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_FREEZE_STATE_PROBE=pass'
Write-Output "PANIC_FREEZE_LAST_OPCODE=$lastOpcode"
Write-Output "PANIC_FREEZE_LAST_RESULT=$lastResult"
Write-Output "PANIC_FREEZE_MODE=$mode"
Write-Output "PANIC_FREEZE_BOOT_PHASE=$bootPhase"
Write-Output "PANIC_FREEZE_PANIC_COUNT=$panicCount"
Write-Output "PANIC_FREEZE_TASK_COUNT=$taskCount"
Write-Output "PANIC_FREEZE_RUNNING_SLOT=$runningSlot"
Write-Output "PANIC_FREEZE_DISPATCH_COUNT=$dispatchCount"