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
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_CANCELED_ENTRY_PRESERVE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_CANCELED_ENTRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-task-resume-timer-clear-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume timer-clear probe failed with exit code $probeExitCode"
}

$POST_RESUME_ENTRY_STATE = Extract-IntValue -Text $probeText -Name 'POST_RESUME_ENTRY_STATE'
$POST_RESUME_NEXT_TIMER_ID = Extract-IntValue -Text $probeText -Name 'POST_RESUME_NEXT_TIMER_ID'
$POST_RESUME_DISPATCH_COUNT = Extract-IntValue -Text $probeText -Name 'POST_RESUME_DISPATCH_COUNT'
if ($null -in @($POST_RESUME_ENTRY_STATE, $POST_RESUME_NEXT_TIMER_ID, $POST_RESUME_DISPATCH_COUNT)) {
    throw 'Missing expected task-resume timer-clear canceled-entry fields in probe output.'
}
if ($POST_RESUME_ENTRY_STATE -ne 3) { throw "Expected POST_RESUME_ENTRY_STATE=3. got $POST_RESUME_ENTRY_STATE" }
if ($POST_RESUME_NEXT_TIMER_ID -ne 2) { throw "Expected POST_RESUME_NEXT_TIMER_ID=2. got $POST_RESUME_NEXT_TIMER_ID" }
if ($POST_RESUME_DISPATCH_COUNT -ne 0) { throw "Expected POST_RESUME_DISPATCH_COUNT=0. got $POST_RESUME_DISPATCH_COUNT" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_CANCELED_ENTRY_PRESERVE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_TIMER_CLEAR_CANCELED_ENTRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-task-resume-timer-clear-probe-check.ps1'
Write-Output "POST_RESUME_ENTRY_STATE=$POST_RESUME_ENTRY_STATE"
Write-Output "POST_RESUME_NEXT_TIMER_ID=$POST_RESUME_NEXT_TIMER_ID"
Write-Output "POST_RESUME_DISPATCH_COUNT=$POST_RESUME_DISPATCH_COUNT"
