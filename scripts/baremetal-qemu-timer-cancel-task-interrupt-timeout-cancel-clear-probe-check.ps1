param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1"
$waitConditionInterruptAny = 3
$taskStateWaiting = 6

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_CANCEL_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_CANCEL_CLEAR_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-cancel-task interrupt-timeout probe failed with exit code $probeExitCode"
}

$cancelTask0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_TASK0_STATE'
$cancelWaitKind0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAIT_KIND0'
$cancelWaitVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAIT_VECTOR0'
$cancelWaitTimeout0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAIT_TIMEOUT0'
$cancelTimerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_TIMER_ENTRY_COUNT'
$cancelTimerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_TIMER_PENDING_WAKE_COUNT'
$cancelWakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAKE_QUEUE_COUNT'

if ($null -in @($cancelTask0State, $cancelWaitKind0, $cancelWaitVector0, $cancelWaitTimeout0, $cancelTimerEntryCount, $cancelTimerPendingWakeCount, $cancelWakeQueueCount)) {
    throw 'Missing expected timer-cancel-task interrupt-timeout cancel-clear fields in probe output.'
}
if ($cancelTask0State -ne $taskStateWaiting) { throw "Expected CANCEL_TASK0_STATE=6, got $cancelTask0State" }
if ($cancelWaitKind0 -ne $waitConditionInterruptAny) { throw "Expected CANCEL_WAIT_KIND0=3, got $cancelWaitKind0" }
if ($cancelWaitVector0 -ne 0) { throw "Expected CANCEL_WAIT_VECTOR0=0, got $cancelWaitVector0" }
if ($cancelWaitTimeout0 -ne 0) { throw "Expected CANCEL_WAIT_TIMEOUT0=0, got $cancelWaitTimeout0" }
if ($cancelTimerEntryCount -ne 0) { throw "Expected CANCEL_TIMER_ENTRY_COUNT=0, got $cancelTimerEntryCount" }
if ($cancelTimerPendingWakeCount -ne 0) { throw "Expected CANCEL_TIMER_PENDING_WAKE_COUNT=0, got $cancelTimerPendingWakeCount" }
if ($cancelWakeQueueCount -ne 0) { throw "Expected CANCEL_WAKE_QUEUE_COUNT=0, got $cancelWakeQueueCount" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_CANCEL_CLEAR_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_CANCEL_CLEAR_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
Write-Output "CANCEL_TASK0_STATE=$cancelTask0State"
Write-Output "CANCEL_WAIT_KIND0=$cancelWaitKind0"
Write-Output "CANCEL_WAIT_VECTOR0=$cancelWaitVector0"
Write-Output "CANCEL_WAIT_TIMEOUT0=$cancelWaitTimeout0"
Write-Output "CANCEL_TIMER_ENTRY_COUNT=$cancelTimerEntryCount"
Write-Output "CANCEL_TIMER_PENDING_WAKE_COUNT=$cancelTimerPendingWakeCount"
Write-Output "CANCEL_WAKE_QUEUE_COUNT=$cancelWakeQueueCount"
