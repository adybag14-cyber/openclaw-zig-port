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
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE_SOURCE=baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-terminate interrupt-timeout probe failed with exit code $probeExitCode"
}

$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_TICKS'
$postTicks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_POST_TICKS'
$schedTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_SCHED_TASK_COUNT'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_TIMER_ENTRY_COUNT'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_TIMER_PENDING_WAKE_COUNT'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_TIMER_DISPATCH_COUNT'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_WAKE_QUEUE_COUNT'
$timerNextTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_TIMER_NEXT_TIMER_ID'

if ($null -in @($ticks, $postTicks, $schedTaskCount, $timerEntryCount, $timerPendingWakeCount, $timerDispatchCount, $wakeQueueCount, $timerNextTimerId)) {
    throw 'Missing expected settled-state fields in task-terminate interrupt-timeout probe output.'
}
if ($ticks -lt ($postTicks + 8)) { throw "Expected TICKS >= POST_TICKS+8. got ticks=$ticks postTicks=$postTicks" }
if ($schedTaskCount -ne 0) { throw "Expected SCHED_TASK_COUNT=0. got $schedTaskCount" }
if ($timerEntryCount -ne 0) { throw "Expected TIMER_ENTRY_COUNT=0. got $timerEntryCount" }
if ($timerPendingWakeCount -ne 0) { throw "Expected TIMER_PENDING_WAKE_COUNT=0. got $timerPendingWakeCount" }
if ($timerDispatchCount -ne 0) { throw "Expected TIMER_DISPATCH_COUNT=0. got $timerDispatchCount" }
if ($wakeQueueCount -ne 0) { throw "Expected WAKE_QUEUE_COUNT=0. got $wakeQueueCount" }
if ($timerNextTimerId -ne 1) { throw "Expected TIMER_NEXT_TIMER_ID=1. got $timerNextTimerId" }

Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE_SOURCE=baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1'
Write-Output "TICKS=$ticks"
Write-Output "POST_TICKS=$postTicks"
Write-Output "SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "TIMER_NEXT_TIMER_ID=$timerNextTimerId"
