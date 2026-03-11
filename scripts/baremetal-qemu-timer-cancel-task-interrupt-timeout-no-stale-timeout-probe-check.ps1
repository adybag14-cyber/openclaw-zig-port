param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1"
$postWakeSlackTicks = 8

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
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-cancel-task interrupt-timeout probe failed with exit code $probeExitCode"
}

$postIdleTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TICK'
$postIdleTask0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TASK0_STATE'
$postIdleWaitKind0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_KIND0'
$postIdleWaitVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_VECTOR0'
$postIdleWaitTimeout0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_TIMEOUT0'
$postIdleTimerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TIMER_ENTRY_COUNT'
$postIdleTimerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TIMER_PENDING_WAKE_COUNT'
$postIdleWakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAKE_QUEUE_COUNT'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_TICK'

if ($null -in @($postIdleTick, $postIdleTask0State, $postIdleWaitKind0, $postIdleWaitVector0, $postIdleWaitTimeout0, $postIdleTimerEntryCount, $postIdleTimerPendingWakeCount, $postIdleWakeQueueCount, $wake0Tick)) {
    throw 'Missing expected timer-cancel-task interrupt-timeout no-stale-timeout fields in probe output.'
}
if ($postIdleTick -lt ($wake0Tick + $postWakeSlackTicks)) { throw "Expected POST_IDLE_TICK >= WAKE0_TICK + $postWakeSlackTicks. tick=$postIdleTick wake=$wake0Tick" }
if ($postIdleTask0State -ne 1) { throw "Expected POST_IDLE_TASK0_STATE=1, got $postIdleTask0State" }
if ($postIdleWaitKind0 -ne 0) { throw "Expected POST_IDLE_WAIT_KIND0=0, got $postIdleWaitKind0" }
if ($postIdleWaitVector0 -ne 0) { throw "Expected POST_IDLE_WAIT_VECTOR0=0, got $postIdleWaitVector0" }
if ($postIdleWaitTimeout0 -ne 0) { throw "Expected POST_IDLE_WAIT_TIMEOUT0=0, got $postIdleWaitTimeout0" }
if ($postIdleTimerEntryCount -ne 0) { throw "Expected POST_IDLE_TIMER_ENTRY_COUNT=0, got $postIdleTimerEntryCount" }
if ($postIdleTimerPendingWakeCount -ne 1) { throw "Expected POST_IDLE_TIMER_PENDING_WAKE_COUNT=1, got $postIdleTimerPendingWakeCount" }
if ($postIdleWakeQueueCount -ne 1) { throw "Expected POST_IDLE_WAKE_QUEUE_COUNT=1, got $postIdleWakeQueueCount" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
Write-Output "POST_IDLE_TICK=$postIdleTick"
Write-Output "POST_IDLE_TASK0_STATE=$postIdleTask0State"
Write-Output "POST_IDLE_WAIT_KIND0=$postIdleWaitKind0"
Write-Output "POST_IDLE_WAIT_VECTOR0=$postIdleWaitVector0"
Write-Output "POST_IDLE_WAIT_TIMEOUT0=$postIdleWaitTimeout0"
Write-Output "POST_IDLE_TIMER_ENTRY_COUNT=$postIdleTimerEntryCount"
Write-Output "POST_IDLE_TIMER_PENDING_WAKE_COUNT=$postIdleTimerPendingWakeCount"
Write-Output "POST_IDLE_WAKE_QUEUE_COUNT=$postIdleWakeQueueCount"
Write-Output "WAKE0_TICK=$wake0Tick"
