param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-task-resume-timer-clear-probe-check.ps1'
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-task-resume-timer-clear-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume timer-clear probe failed with exit code $probeExitCode"
}

$TASK_ID = Extract-IntValue -Text $probeText -Name 'TASK_ID'
$PRE_TASK_STATE = Extract-IntValue -Text $probeText -Name 'PRE_TASK_STATE'
$PRE_TIMER_COUNT = Extract-IntValue -Text $probeText -Name 'PRE_TIMER_COUNT'
$PRE_NEXT_TIMER_ID = Extract-IntValue -Text $probeText -Name 'PRE_NEXT_TIMER_ID'
if ($null -in @($TASK_ID, $PRE_TASK_STATE, $PRE_TIMER_COUNT, $PRE_NEXT_TIMER_ID)) {
    throw 'Missing expected task-resume timer-clear baseline fields in probe output.'
}
if ($TASK_ID -le 0) { throw "Expected TASK_ID>0. got $TASK_ID" }
if ($PRE_TASK_STATE -ne 6) { throw "Expected PRE_TASK_STATE=6. got $PRE_TASK_STATE" }
if ($PRE_TIMER_COUNT -ne 1) { throw "Expected PRE_TIMER_COUNT=1. got $PRE_TIMER_COUNT" }
if ($PRE_NEXT_TIMER_ID -ne 2) { throw "Expected PRE_NEXT_TIMER_ID=2. got $PRE_NEXT_TIMER_ID" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-task-resume-timer-clear-probe-check.ps1'
Write-Output "TASK_ID=$TASK_ID"
Write-Output "PRE_TASK_STATE=$PRE_TASK_STATE"
Write-Output "PRE_TIMER_COUNT=$PRE_TIMER_COUNT"
Write-Output "PRE_NEXT_TIMER_ID=$PRE_NEXT_TIMER_ID"
