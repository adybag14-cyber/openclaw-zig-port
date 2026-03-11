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
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_NO_LATE_INTERRUPT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_NO_LATE_INTERRUPT_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume interrupt probe failed with exit code $probeExitCode"
}

$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_INTERRUPT_COUNT'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAKE_QUEUE_COUNT'
$wake0Seq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAKE0_SEQ'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TIMER_DISPATCH_COUNT'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TIMER_PENDING_WAKE_COUNT'

if ($null -in @($interruptCount, $wakeQueueCount, $wake0Seq, $timerDispatchCount, $timerPendingWakeCount)) {
    throw 'Missing expected task-resume interrupt no-late-interrupt fields in probe output.'
}
if ($interruptCount -ne 1) { throw "Expected INTERRUPT_COUNT=1 after later interrupt. got $interruptCount" }
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1 with no second wake. got $wakeQueueCount" }
if ($wake0Seq -ne 1) { throw "Expected WAKE0_SEQ=1 with preserved manual wake. got $wake0Seq" }
if ($timerDispatchCount -ne 0) { throw "Expected TIMER_DISPATCH_COUNT=0. got $timerDispatchCount" }
if ($timerPendingWakeCount -ne 1) { throw "Expected TIMER_PENDING_WAKE_COUNT=1. got $timerPendingWakeCount" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_NO_LATE_INTERRUPT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_NO_LATE_INTERRUPT_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_SEQ=$wake0Seq"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
