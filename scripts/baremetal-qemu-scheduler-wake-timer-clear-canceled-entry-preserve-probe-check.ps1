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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_CANCELED_ENTRY_PRESERVE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-wake timer-clear probe failed with exit code $probeExitCode"
}

$postResumeEntryState = Extract-IntValue -Text $probeText -Name 'POST_RESUME_ENTRY_STATE'
$postIdleTimerCount = Extract-IntValue -Text $probeText -Name 'POST_IDLE_TIMER_COUNT'
$postIdleQuantum = Extract-IntValue -Text $probeText -Name 'POST_IDLE_QUANTUM'

if ($null -in @($postResumeEntryState, $postIdleTimerCount, $postIdleQuantum)) {
    throw 'Missing expected scheduler-wake timer-clear canceled-entry fields in probe output.'
}
if ($postResumeEntryState -ne 3) { throw "Expected POST_RESUME_ENTRY_STATE=3. got $postResumeEntryState" }
if ($postIdleTimerCount -ne 0) { throw "Expected POST_IDLE_TIMER_COUNT=0. got $postIdleTimerCount" }
if ($postIdleQuantum -ne 5) { throw "Expected POST_IDLE_QUANTUM=5. got $postIdleQuantum" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_CANCELED_ENTRY_PRESERVE_PROBE=pass'
Write-Output "POST_RESUME_ENTRY_STATE=$postResumeEntryState"
Write-Output "POST_IDLE_TIMER_COUNT=$postIdleTimerCount"
Write-Output "POST_IDLE_QUANTUM=$postIdleQuantum"