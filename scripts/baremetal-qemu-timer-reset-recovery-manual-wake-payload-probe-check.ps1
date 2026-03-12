param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-reset-recovery-probe-check.ps1"
$wakeReasonManual = 3

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
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_MANUAL_WAKE_PAYLOAD_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_MANUAL_WAKE_PAYLOAD_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-reset-recovery probe failed with exit code $probeExitCode"
}

$TASK0_ID = Extract-IntValue -Text $probeText -Name 'TASK0_ID'
$AFTER_MANUAL_WAKE_COUNT = Extract-IntValue -Text $probeText -Name 'AFTER_MANUAL_WAKE_COUNT'
$WAKE0_TASK_ID = Extract-IntValue -Text $probeText -Name 'WAKE0_TASK_ID'
$WAKE0_TIMER_ID = Extract-IntValue -Text $probeText -Name 'WAKE0_TIMER_ID'
$WAKE0_REASON = Extract-IntValue -Text $probeText -Name 'WAKE0_REASON'
$WAKE0_VECTOR = Extract-IntValue -Text $probeText -Name 'WAKE0_VECTOR'

if ($null -in @($TASK0_ID, $AFTER_MANUAL_WAKE_COUNT, $WAKE0_TASK_ID, $WAKE0_TIMER_ID, $WAKE0_REASON, $WAKE0_VECTOR)) {
    throw 'Missing expected timer-reset-recovery manual-wake payload fields in probe output.'
}
if ($AFTER_MANUAL_WAKE_COUNT -ne 1) { throw "Expected AFTER_MANUAL_WAKE_COUNT=1. got $AFTER_MANUAL_WAKE_COUNT" }
if ($WAKE0_TASK_ID -ne $TASK0_ID) { throw "Expected WAKE0_TASK_ID=$TASK0_ID. got $WAKE0_TASK_ID" }
if ($WAKE0_TIMER_ID -ne 0) { throw "Expected WAKE0_TIMER_ID=0. got $WAKE0_TIMER_ID" }
if ($WAKE0_REASON -ne $wakeReasonManual) { throw "Expected WAKE0_REASON=3. got $WAKE0_REASON" }
if ($WAKE0_VECTOR -ne 0) { throw "Expected WAKE0_VECTOR=0. got $WAKE0_VECTOR" }

Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_MANUAL_WAKE_PAYLOAD_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_MANUAL_WAKE_PAYLOAD_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
Write-Output "AFTER_MANUAL_WAKE_COUNT=$AFTER_MANUAL_WAKE_COUNT"
Write-Output "WAKE0_TASK_ID=$WAKE0_TASK_ID"
Write-Output "WAKE0_TIMER_ID=$WAKE0_TIMER_ID"
Write-Output "WAKE0_REASON=$WAKE0_REASON"
Write-Output "WAKE0_VECTOR=$WAKE0_VECTOR"
