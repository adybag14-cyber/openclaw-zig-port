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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_REARM_TELEMETRY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-wake timer-clear probe failed with exit code $probeExitCode"
}

$postResumeDispatchCount = Extract-IntValue -Text $probeText -Name 'POST_RESUME_DISPATCH_COUNT'
$postIdleDispatchCount = Extract-IntValue -Text $probeText -Name 'POST_IDLE_DISPATCH_COUNT'
$rearmTimerId = Extract-IntValue -Text $probeText -Name 'REARM_TIMER_ID'
$rearmNextTimerId = Extract-IntValue -Text $probeText -Name 'REARM_NEXT_TIMER_ID'

if ($null -in @($postResumeDispatchCount, $postIdleDispatchCount, $rearmTimerId, $rearmNextTimerId)) {
    throw 'Missing expected scheduler-wake timer-clear rearm fields in probe output.'
}
if ($postResumeDispatchCount -ne 0) { throw "Expected POST_RESUME_DISPATCH_COUNT=0. got $postResumeDispatchCount" }
if ($postIdleDispatchCount -ne 0) { throw "Expected POST_IDLE_DISPATCH_COUNT=0. got $postIdleDispatchCount" }
if ($rearmTimerId -ne 2) { throw "Expected REARM_TIMER_ID=2. got $rearmTimerId" }
if ($rearmNextTimerId -ne 3) { throw "Expected REARM_NEXT_TIMER_ID=3. got $rearmNextTimerId" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_REARM_TELEMETRY_PROBE=pass'
Write-Output "POST_RESUME_DISPATCH_COUNT=$postResumeDispatchCount"
Write-Output "POST_IDLE_DISPATCH_COUNT=$postIdleDispatchCount"
Write-Output "REARM_TIMER_ID=$rearmTimerId"
Write-Output "REARM_NEXT_TIMER_ID=$rearmNextTimerId"