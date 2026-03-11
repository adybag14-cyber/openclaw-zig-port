param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-terminate-mixed-state-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_IDLE_STABILITY_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_IDLE_STABILITY_PROBE_SOURCE=baremetal-qemu-task-terminate-mixed-state-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-terminate mixed-state probe failed with exit code $probeExitCode"
}

$survivorTaskId = Extract-IntValue -Text $probeText -Name 'PRE_SURVIVOR_TASK_ID'
$afterIdleWakeCount = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_WAKE_COUNT'
$afterIdlePendingWakeCount = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_PENDING_WAKE_COUNT'
$afterIdleTimerCount = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_TIMER_COUNT'
$afterIdleTimerDispatchCount = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_TIMER_DISPATCH_COUNT'
$afterIdleNextTimerId = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_NEXT_TIMER_ID'
$afterIdleQuantum = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_QUANTUM'
$afterIdleWake0TaskId = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_WAKE0_TASK_ID'

if ($null -in @($survivorTaskId, $afterIdleWakeCount, $afterIdlePendingWakeCount, $afterIdleTimerCount, $afterIdleTimerDispatchCount, $afterIdleNextTimerId, $afterIdleQuantum, $afterIdleWake0TaskId)) {
    throw 'Missing expected idle-stability fields in task-terminate mixed-state probe output.'
}
if ($survivorTaskId -le 0) { throw "Expected non-zero PRE_SURVIVOR_TASK_ID. got $survivorTaskId" }
if ($afterIdleWakeCount -ne 1) { throw "Expected AFTER_IDLE_WAKE_COUNT=1. got $afterIdleWakeCount" }
if ($afterIdlePendingWakeCount -ne 1) { throw "Expected AFTER_IDLE_PENDING_WAKE_COUNT=1. got $afterIdlePendingWakeCount" }
if ($afterIdleTimerCount -ne 0) { throw "Expected AFTER_IDLE_TIMER_COUNT=0. got $afterIdleTimerCount" }
if ($afterIdleTimerDispatchCount -ne 0) { throw "Expected AFTER_IDLE_TIMER_DISPATCH_COUNT=0. got $afterIdleTimerDispatchCount" }
if ($afterIdleNextTimerId -ne 2) { throw "Expected AFTER_IDLE_NEXT_TIMER_ID=2. got $afterIdleNextTimerId" }
if ($afterIdleQuantum -ne 5) { throw "Expected AFTER_IDLE_QUANTUM=5. got $afterIdleQuantum" }
if ($afterIdleWake0TaskId -ne $survivorTaskId) { throw "Expected AFTER_IDLE_WAKE0_TASK_ID=$survivorTaskId. got $afterIdleWake0TaskId" }

Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_IDLE_STABILITY_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_IDLE_STABILITY_PROBE_SOURCE=baremetal-qemu-task-terminate-mixed-state-probe-check.ps1'
Write-Output "PRE_SURVIVOR_TASK_ID=$survivorTaskId"
Write-Output "AFTER_IDLE_WAKE_COUNT=$afterIdleWakeCount"
Write-Output "AFTER_IDLE_PENDING_WAKE_COUNT=$afterIdlePendingWakeCount"
Write-Output "AFTER_IDLE_TIMER_COUNT=$afterIdleTimerCount"
Write-Output "AFTER_IDLE_TIMER_DISPATCH_COUNT=$afterIdleTimerDispatchCount"
Write-Output "AFTER_IDLE_NEXT_TIMER_ID=$afterIdleNextTimerId"
Write-Output "AFTER_IDLE_QUANTUM=$afterIdleQuantum"
Write-Output "AFTER_IDLE_WAKE0_TASK_ID=$afterIdleWake0TaskId"
