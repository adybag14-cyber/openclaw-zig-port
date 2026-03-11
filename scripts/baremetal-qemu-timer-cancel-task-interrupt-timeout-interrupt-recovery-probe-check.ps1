param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_INTERRUPT_RECOVERY_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_INTERRUPT_RECOVERY_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying timer-cancel-task interrupt-timeout probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TASK0_ID'
$waitKind = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_KIND0'
$waitTimeout = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_TIMEOUT0'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TIMER_ENTRY_COUNT'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TIMER_PENDING_WAKE_COUNT'
$timerNextTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_NEXT_TIMER_ID'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAKE_QUEUE_COUNT'
$wakeTaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_TASK_ID'
$wakeReason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_REASON'
$wakeVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_VECTOR'
$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_INTERRUPT_COUNT'
$timerLastInterruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_LAST_INTERRUPT_COUNT'
$lastInterruptVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_LAST_INTERRUPT_VECTOR'

if ($null -in @($taskId, $waitKind, $waitTimeout, $timerEntryCount, $timerPendingWakeCount, $timerNextTimerId, $wakeQueueCount, $wakeTaskId, $wakeReason, $wakeVector, $interruptCount, $timerLastInterruptCount, $lastInterruptVector)) {
    throw 'Missing expected timer-cancel-task interrupt-timeout recovery fields in probe output.'
}
if ($taskId -le 0) { throw "Expected TASK0_ID>0. got $taskId" }
if ($waitKind -ne 0) { throw "Expected WAIT_KIND0=0 after cancel + interrupt recovery. got $waitKind" }
if ($waitTimeout -ne 0) { throw "Expected WAIT_TIMEOUT0=0 after cancel. got $waitTimeout" }
if ($timerEntryCount -ne 0) { throw "Expected TIMER_ENTRY_COUNT=0 after cancel. got $timerEntryCount" }
if ($timerPendingWakeCount -ne 1) { throw "Expected TIMER_PENDING_WAKE_COUNT=1 after later real interrupt wake. got $timerPendingWakeCount" }
if ($timerNextTimerId -ne 1) { throw "Expected TIMER_NEXT_TIMER_ID=1 after cancel path. got $timerNextTimerId" }
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1 after later interrupt wake. got $wakeQueueCount" }
if ($wakeTaskId -ne $taskId) { throw "Expected WAKE0_TASK_ID=$taskId. got $wakeTaskId" }
if ($wakeReason -ne 2) { throw "Expected WAKE0_REASON=2 for interrupt wake. got $wakeReason" }
if ($wakeVector -ne 200) { throw "Expected WAKE0_VECTOR=200. got $wakeVector" }
if ($interruptCount -ne 1) { throw "Expected INTERRUPT_COUNT=1. got $interruptCount" }
if ($timerLastInterruptCount -ne 1) { throw "Expected TIMER_LAST_INTERRUPT_COUNT=1. got $timerLastInterruptCount" }
if ($lastInterruptVector -ne 200) { throw "Expected LAST_INTERRUPT_VECTOR=200. got $lastInterruptVector" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_INTERRUPT_RECOVERY_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_INTERRUPT_RECOVERY_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
Write-Output "TASK0_ID=$taskId"
Write-Output "POST_IDLE_WAIT_KIND0=$waitKind"
Write-Output "POST_IDLE_WAIT_TIMEOUT0=$waitTimeout"
Write-Output "POST_IDLE_TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "POST_IDLE_TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "TIMER_NEXT_TIMER_ID=$timerNextTimerId"
Write-Output "POST_IDLE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_TASK_ID=$wakeTaskId"
Write-Output "WAKE0_REASON=$wakeReason"
Write-Output "WAKE0_VECTOR=$wakeVector"
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "LAST_INTERRUPT_VECTOR=$lastInterruptVector"
