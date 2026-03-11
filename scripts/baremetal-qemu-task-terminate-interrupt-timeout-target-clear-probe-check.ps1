param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1"
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_TARGET_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_TARGET_CLEAR_PROBE_SOURCE=baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-terminate interrupt-timeout probe failed with exit code $probeExitCode"
}

$postTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_TASK_COUNT'
$postTask0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_TASK0_STATE'
$postWaitKind0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_WAIT_KIND0'
$postWaitTimeout0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_WAIT_TIMEOUT0'
$postTimerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_TIMER_ENTRY_COUNT'
$postTimerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_TIMER_PENDING_WAKE_COUNT'
$postTimerNextTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_TIMER_NEXT_TIMER_ID'
$postWakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_WAKE_QUEUE_COUNT'

if ($null -in @($postTaskCount, $postTask0State, $postWaitKind0, $postWaitTimeout0, $postTimerEntryCount, $postTimerPendingWakeCount, $postTimerNextTimerId, $postWakeQueueCount)) {
    throw 'Missing expected post-terminate fields in task-terminate interrupt-timeout probe output.'
}
if ($postTaskCount -ne 0) { throw "Expected POST_TASK_COUNT=0. got $postTaskCount" }
if ($postTask0State -ne 4) { throw "Expected POST_TASK0_STATE=4. got $postTask0State" }
if ($postWaitKind0 -ne 0) { throw "Expected POST_WAIT_KIND0=0. got $postWaitKind0" }
if ($postWaitTimeout0 -ne 0) { throw "Expected POST_WAIT_TIMEOUT0=0. got $postWaitTimeout0" }
if ($postTimerEntryCount -ne 0) { throw "Expected POST_TIMER_ENTRY_COUNT=0. got $postTimerEntryCount" }
if ($postTimerPendingWakeCount -ne 0) { throw "Expected POST_TIMER_PENDING_WAKE_COUNT=0. got $postTimerPendingWakeCount" }
if ($postTimerNextTimerId -ne 1) { throw "Expected POST_TIMER_NEXT_TIMER_ID=1. got $postTimerNextTimerId" }
if ($postWakeQueueCount -ne 0) { throw "Expected POST_WAKE_QUEUE_COUNT=0. got $postWakeQueueCount" }

Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_TARGET_CLEAR_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_TARGET_CLEAR_PROBE_SOURCE=baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1'
Write-Output "POST_TASK_COUNT=$postTaskCount"
Write-Output "POST_TASK0_STATE=$postTask0State"
Write-Output "POST_WAIT_KIND0=$postWaitKind0"
Write-Output "POST_WAIT_TIMEOUT0=$postWaitTimeout0"
Write-Output "POST_TIMER_ENTRY_COUNT=$postTimerEntryCount"
Write-Output "POST_TIMER_PENDING_WAKE_COUNT=$postTimerPendingWakeCount"
Write-Output "POST_TIMER_NEXT_TIMER_ID=$postTimerNextTimerId"
Write-Output "POST_WAKE_QUEUE_COUNT=$postWakeQueueCount"
