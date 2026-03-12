param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-reset-recovery-probe-check.ps1"
$wakeReasonInterrupt = 2
$interruptVector = 31

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_INTERRUPT_REARM_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_INTERRUPT_REARM_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-reset-recovery probe failed with exit code $probeExitCode"
}

$TASK1_ID = Extract-IntValue -Text $probeText -Name 'TASK1_ID'
$AFTER_INTERRUPT_WAKE_COUNT = Extract-IntValue -Text $probeText -Name 'AFTER_INTERRUPT_WAKE_COUNT'
$WAKE1_TASK_ID = Extract-IntValue -Text $probeText -Name 'WAKE1_TASK_ID'
$WAKE1_TIMER_ID = Extract-IntValue -Text $probeText -Name 'WAKE1_TIMER_ID'
$WAKE1_REASON = Extract-IntValue -Text $probeText -Name 'WAKE1_REASON'
$WAKE1_VECTOR = Extract-IntValue -Text $probeText -Name 'WAKE1_VECTOR'
$REARM_TIMER_COUNT = Extract-IntValue -Text $probeText -Name 'REARM_TIMER_COUNT'
$REARM_TIMER_ID = Extract-IntValue -Text $probeText -Name 'REARM_TIMER_ID'
$REARM_NEXT_TIMER_ID = Extract-IntValue -Text $probeText -Name 'REARM_NEXT_TIMER_ID'

if ($null -in @($TASK1_ID, $AFTER_INTERRUPT_WAKE_COUNT, $WAKE1_TASK_ID, $WAKE1_TIMER_ID, $WAKE1_REASON, $WAKE1_VECTOR, $REARM_TIMER_COUNT, $REARM_TIMER_ID, $REARM_NEXT_TIMER_ID)) {
    throw 'Missing expected timer-reset-recovery interrupt/rearm fields in probe output.'
}
if ($AFTER_INTERRUPT_WAKE_COUNT -ne 2) { throw "Expected AFTER_INTERRUPT_WAKE_COUNT=2. got $AFTER_INTERRUPT_WAKE_COUNT" }
if ($WAKE1_TASK_ID -ne $TASK1_ID) { throw "Expected WAKE1_TASK_ID=$TASK1_ID. got $WAKE1_TASK_ID" }
if ($WAKE1_TIMER_ID -ne 0) { throw "Expected WAKE1_TIMER_ID=0. got $WAKE1_TIMER_ID" }
if ($WAKE1_REASON -ne $wakeReasonInterrupt) { throw "Expected WAKE1_REASON=2. got $WAKE1_REASON" }
if ($WAKE1_VECTOR -ne $interruptVector) { throw "Expected WAKE1_VECTOR=31. got $WAKE1_VECTOR" }
if ($REARM_TIMER_COUNT -ne 1) { throw "Expected REARM_TIMER_COUNT=1. got $REARM_TIMER_COUNT" }
if ($REARM_TIMER_ID -ne 1) { throw "Expected REARM_TIMER_ID=1. got $REARM_TIMER_ID" }
if ($REARM_NEXT_TIMER_ID -ne 2) { throw "Expected REARM_NEXT_TIMER_ID=2. got $REARM_NEXT_TIMER_ID" }

Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_INTERRUPT_REARM_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_INTERRUPT_REARM_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
Write-Output "AFTER_INTERRUPT_WAKE_COUNT=$AFTER_INTERRUPT_WAKE_COUNT"
Write-Output "WAKE1_TASK_ID=$WAKE1_TASK_ID"
Write-Output "WAKE1_TIMER_ID=$WAKE1_TIMER_ID"
Write-Output "WAKE1_REASON=$WAKE1_REASON"
Write-Output "WAKE1_VECTOR=$WAKE1_VECTOR"
Write-Output "REARM_TIMER_COUNT=$REARM_TIMER_COUNT"
Write-Output "REARM_TIMER_ID=$REARM_TIMER_ID"
Write-Output "REARM_NEXT_TIMER_ID=$REARM_NEXT_TIMER_ID"
