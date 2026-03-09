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
    Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_FINAL_TASK_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-wake recovery probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'
$mode = Extract-IntValue -Text $probeText -Name 'MODE'
$bootPhase = Extract-IntValue -Text $probeText -Name 'BOOT_PHASE'
$panicCount = Extract-IntValue -Text $probeText -Name 'PANIC_COUNT'
$taskCount = Extract-IntValue -Text $probeText -Name 'TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'RUNNING_SLOT'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'DISPATCH_COUNT'
$task0RunCount = Extract-IntValue -Text $probeText -Name 'TASK0_RUN_COUNT'
$task1RunCount = Extract-IntValue -Text $probeText -Name 'TASK1_RUN_COUNT'
$task1BudgetRemaining = Extract-IntValue -Text $probeText -Name 'TASK1_BUDGET_REMAINING'

if ($null -in @($ack, $lastOpcode, $lastResult, $mode, $bootPhase, $panicCount, $taskCount, $runningSlot, $dispatchCount, $task0RunCount, $task1RunCount, $task1BudgetRemaining)) {
    throw 'Missing expected final-state fields in panic-wake recovery probe output.'
}
if ($ack -ne 13) { throw "Expected ACK=13. got $ack" }
if ($lastOpcode -ne 16) { throw "Expected LAST_OPCODE=16. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($mode -ne 1) { throw "Expected MODE=1. got $mode" }
if ($bootPhase -ne 2) { throw "Expected BOOT_PHASE=2. got $bootPhase" }
if ($panicCount -ne 1) { throw "Expected PANIC_COUNT=1. got $panicCount" }
if ($taskCount -ne 2) { throw "Expected TASK_COUNT=2. got $taskCount" }
if ($runningSlot -ne 1) { throw "Expected RUNNING_SLOT=1. got $runningSlot" }
if ($dispatchCount -ne 2) { throw "Expected DISPATCH_COUNT=2. got $dispatchCount" }
if ($task0RunCount -ne 1) { throw "Expected TASK0_RUN_COUNT=1. got $task0RunCount" }
if ($task1RunCount -ne 1) { throw "Expected TASK1_RUN_COUNT=1. got $task1RunCount" }
if ($task1BudgetRemaining -ne 6) { throw "Expected TASK1_BUDGET_REMAINING=6. got $task1BudgetRemaining" }

Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_FINAL_TASK_STATE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MODE=$mode"
Write-Output "BOOT_PHASE=$bootPhase"
Write-Output "PANIC_COUNT=$panicCount"
Write-Output "TASK_COUNT=$taskCount"
Write-Output "RUNNING_SLOT=$runningSlot"
Write-Output "DISPATCH_COUNT=$dispatchCount"
Write-Output "TASK0_RUN_COUNT=$task0RunCount"
Write-Output "TASK1_RUN_COUNT=$task1RunCount"
Write-Output "TASK1_BUDGET_REMAINING=$task1BudgetRemaining"