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
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_BASELINE_PROBE_SOURCE=baremetal-qemu-task-terminate-mixed-state-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-terminate mixed-state probe failed with exit code $probeExitCode"
}

$terminatedTaskId = Extract-IntValue -Text $probeText -Name 'PRE_TERMINATED_TASK_ID'
$survivorTaskId = Extract-IntValue -Text $probeText -Name 'PRE_SURVIVOR_TASK_ID'
$preWakeCount = Extract-IntValue -Text $probeText -Name 'PRE_WAKE_COUNT'
$prePendingWakeCount = Extract-IntValue -Text $probeText -Name 'PRE_PENDING_WAKE_COUNT'
$preTimerCount = Extract-IntValue -Text $probeText -Name 'PRE_TIMER_COUNT'
$preNextTimerId = Extract-IntValue -Text $probeText -Name 'PRE_NEXT_TIMER_ID'
$preQuantum = Extract-IntValue -Text $probeText -Name 'PRE_QUANTUM'
$preWake0TaskId = Extract-IntValue -Text $probeText -Name 'PRE_WAKE0_TASK_ID'
$preWake1TaskId = Extract-IntValue -Text $probeText -Name 'PRE_WAKE1_TASK_ID'
$preTimer0State = Extract-IntValue -Text $probeText -Name 'PRE_TIMER0_STATE'

if ($null -in @($terminatedTaskId, $survivorTaskId, $preWakeCount, $prePendingWakeCount, $preTimerCount, $preNextTimerId, $preQuantum, $preWake0TaskId, $preWake1TaskId, $preTimer0State)) {
    throw 'Missing expected baseline fields in task-terminate mixed-state probe output.'
}
if ($terminatedTaskId -le 0 -or $survivorTaskId -le 0 -or $terminatedTaskId -eq $survivorTaskId) {
    throw "Expected distinct non-zero task ids. terminated=$terminatedTaskId survivor=$survivorTaskId"
}
if ($preWakeCount -ne 2) { throw "Expected PRE_WAKE_COUNT=2. got $preWakeCount" }
if ($prePendingWakeCount -ne 2) { throw "Expected PRE_PENDING_WAKE_COUNT=2. got $prePendingWakeCount" }
if ($preTimerCount -ne 0) { throw "Expected PRE_TIMER_COUNT=0. got $preTimerCount" }
if ($preNextTimerId -ne 2) { throw "Expected PRE_NEXT_TIMER_ID=2. got $preNextTimerId" }
if ($preQuantum -ne 5) { throw "Expected PRE_QUANTUM=5. got $preQuantum" }
if ($preWake0TaskId -ne $terminatedTaskId) { throw "Expected PRE_WAKE0_TASK_ID=$terminatedTaskId. got $preWake0TaskId" }
if ($preWake1TaskId -ne $survivorTaskId) { throw "Expected PRE_WAKE1_TASK_ID=$survivorTaskId. got $preWake1TaskId" }
if ($preTimer0State -ne 3) { throw "Expected PRE_TIMER0_STATE=3. got $preTimer0State" }

Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_BASELINE_PROBE_SOURCE=baremetal-qemu-task-terminate-mixed-state-probe-check.ps1'
Write-Output "PRE_TERMINATED_TASK_ID=$terminatedTaskId"
Write-Output "PRE_SURVIVOR_TASK_ID=$survivorTaskId"
Write-Output "PRE_WAKE_COUNT=$preWakeCount"
Write-Output "PRE_PENDING_WAKE_COUNT=$prePendingWakeCount"
Write-Output "PRE_TIMER_COUNT=$preTimerCount"
Write-Output "PRE_NEXT_TIMER_ID=$preNextTimerId"
Write-Output "PRE_QUANTUM=$preQuantum"
Write-Output "PRE_WAKE0_TASK_ID=$preWake0TaskId"
Write-Output "PRE_WAKE1_TASK_ID=$preWake1TaskId"
Write-Output "PRE_TIMER0_STATE=$preTimer0State"
