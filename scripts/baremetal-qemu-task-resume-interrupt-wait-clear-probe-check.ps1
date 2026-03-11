param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-resume-interrupt-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_WAIT_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_WAIT_CLEAR_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume interrupt probe failed with exit code $probeExitCode"
}

$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_STATE'
$waitKind = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAIT_KIND0'
$waitVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAIT_VECTOR0'
$waitTimeout = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAIT_TIMEOUT0'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TIMER_ENTRY_COUNT'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TIMER_PENDING_WAKE_COUNT'
$timerNextTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TIMER_NEXT_TIMER_ID'

if ($null -in @($task0State, $waitKind, $waitVector, $waitTimeout, $timerEntryCount, $timerPendingWakeCount, $timerNextTimerId)) {
    throw 'Missing expected task-resume interrupt wait-clear fields in probe output.'
}
if ($task0State -ne 1) { throw "Expected TASK0_STATE=1 after resume. got $task0State" }
if ($waitKind -ne 0) { throw "Expected WAIT_KIND0=0 after resume. got $waitKind" }
if ($waitVector -ne 0) { throw "Expected WAIT_VECTOR0=0 after resume. got $waitVector" }
if ($waitTimeout -ne 0) { throw "Expected WAIT_TIMEOUT0=0 after resume. got $waitTimeout" }
if ($timerEntryCount -ne 0) { throw "Expected TIMER_ENTRY_COUNT=0 after resume. got $timerEntryCount" }
if ($timerPendingWakeCount -ne 1) { throw "Expected TIMER_PENDING_WAKE_COUNT=1 after resume. got $timerPendingWakeCount" }
if ($timerNextTimerId -ne 1) { throw "Expected TIMER_NEXT_TIMER_ID=1 after resume. got $timerNextTimerId" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_WAIT_CLEAR_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_WAIT_CLEAR_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
Write-Output "TASK0_STATE=$task0State"
Write-Output "WAIT_KIND0=$waitKind"
Write-Output "WAIT_VECTOR0=$waitVector"
Write-Output "WAIT_TIMEOUT0=$waitTimeout"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "TIMER_NEXT_TIMER_ID=$timerNextTimerId"
