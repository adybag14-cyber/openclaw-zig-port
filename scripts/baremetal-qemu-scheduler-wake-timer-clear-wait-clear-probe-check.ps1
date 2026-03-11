param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-wake-timer-clear-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_WAIT_CLEAR_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-wake timer-clear probe failed with exit code $probeExitCode"
}

$postResumeTaskState = Extract-IntValue -Text $probeText -Name 'POST_RESUME_TASK_STATE'
$postResumeTimerCount = Extract-IntValue -Text $probeText -Name 'POST_RESUME_TIMER_COUNT'
$postResumeNextTimerId = Extract-IntValue -Text $probeText -Name 'POST_RESUME_NEXT_TIMER_ID'
$postIdleWakeCount = Extract-IntValue -Text $probeText -Name 'POST_IDLE_WAKE_COUNT'
$postIdleTimerCount = Extract-IntValue -Text $probeText -Name 'POST_IDLE_TIMER_COUNT'

if ($null -in @($postResumeTaskState, $postResumeTimerCount, $postResumeNextTimerId, $postIdleWakeCount, $postIdleTimerCount)) {
    throw 'Missing expected scheduler-wake timer-clear wait-clear fields in probe output.'
}
if ($postResumeTaskState -ne 1) { throw "Expected POST_RESUME_TASK_STATE=1. got $postResumeTaskState" }
if ($postResumeTimerCount -ne 0) { throw "Expected POST_RESUME_TIMER_COUNT=0. got $postResumeTimerCount" }
if ($postResumeNextTimerId -ne 2) { throw "Expected POST_RESUME_NEXT_TIMER_ID=2. got $postResumeNextTimerId" }
if ($postIdleWakeCount -ne 1) { throw "Expected POST_IDLE_WAKE_COUNT=1. got $postIdleWakeCount" }
if ($postIdleTimerCount -ne 0) { throw "Expected POST_IDLE_TIMER_COUNT=0. got $postIdleTimerCount" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_WAIT_CLEAR_PROBE=pass'
Write-Output "POST_RESUME_TASK_STATE=$postResumeTaskState"
Write-Output "POST_RESUME_TIMER_COUNT=$postResumeTimerCount"
Write-Output "POST_RESUME_NEXT_TIMER_ID=$postResumeNextTimerId"
Write-Output "POST_IDLE_WAKE_COUNT=$postIdleWakeCount"
Write-Output "POST_IDLE_TIMER_COUNT=$postIdleTimerCount"