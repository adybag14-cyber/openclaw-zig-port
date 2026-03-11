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
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_REARM_TELEMETRY_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_REARM_TELEMETRY_PROBE_SOURCE=baremetal-qemu-task-resume-timer-clear-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume timer-clear probe failed with exit code $probeExitCode"
}

$POST_IDLE_WAKE_COUNT = Extract-IntValue -Text $probeText -Name 'POST_IDLE_WAKE_COUNT'
$POST_IDLE_TIMER_COUNT = Extract-IntValue -Text $probeText -Name 'POST_IDLE_TIMER_COUNT'
$POST_IDLE_DISPATCH_COUNT = Extract-IntValue -Text $probeText -Name 'POST_IDLE_DISPATCH_COUNT'
$POST_IDLE_QUANTUM = Extract-IntValue -Text $probeText -Name 'POST_IDLE_QUANTUM'
$REARM_TIMER_ID = Extract-IntValue -Text $probeText -Name 'REARM_TIMER_ID'
$REARM_NEXT_TIMER_ID = Extract-IntValue -Text $probeText -Name 'REARM_NEXT_TIMER_ID'
if ($null -in @($POST_IDLE_WAKE_COUNT, $POST_IDLE_TIMER_COUNT, $POST_IDLE_DISPATCH_COUNT, $POST_IDLE_QUANTUM, $REARM_TIMER_ID, $REARM_NEXT_TIMER_ID)) {
    throw 'Missing expected task-resume timer-clear rearm/telemetry fields in probe output.'
}
if ($POST_IDLE_WAKE_COUNT -ne 1) { throw "Expected POST_IDLE_WAKE_COUNT=1. got $POST_IDLE_WAKE_COUNT" }
if ($POST_IDLE_TIMER_COUNT -ne 0) { throw "Expected POST_IDLE_TIMER_COUNT=0. got $POST_IDLE_TIMER_COUNT" }
if ($POST_IDLE_DISPATCH_COUNT -ne 0) { throw "Expected POST_IDLE_DISPATCH_COUNT=0. got $POST_IDLE_DISPATCH_COUNT" }
if ($POST_IDLE_QUANTUM -ne 5) { throw "Expected POST_IDLE_QUANTUM=5. got $POST_IDLE_QUANTUM" }
if ($REARM_TIMER_ID -ne 2) { throw "Expected REARM_TIMER_ID=2. got $REARM_TIMER_ID" }
if ($REARM_NEXT_TIMER_ID -ne 3) { throw "Expected REARM_NEXT_TIMER_ID=3. got $REARM_NEXT_TIMER_ID" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_REARM_TELEMETRY_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_REARM_TELEMETRY_PROBE_SOURCE=baremetal-qemu-task-resume-timer-clear-probe-check.ps1'
Write-Output "POST_IDLE_WAKE_COUNT=$POST_IDLE_WAKE_COUNT"
Write-Output "POST_IDLE_TIMER_COUNT=$POST_IDLE_TIMER_COUNT"
Write-Output "POST_IDLE_DISPATCH_COUNT=$POST_IDLE_DISPATCH_COUNT"
Write-Output "POST_IDLE_QUANTUM=$POST_IDLE_QUANTUM"
Write-Output "REARM_TIMER_ID=$REARM_TIMER_ID"
Write-Output "REARM_NEXT_TIMER_ID=$REARM_NEXT_TIMER_ID"
