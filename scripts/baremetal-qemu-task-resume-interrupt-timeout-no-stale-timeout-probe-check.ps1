param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume interrupt-timeout probe failed with exit code $probeExitCode"
}

$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TICKS'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_WAKE0_TICK'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TIMER_ENTRY_COUNT'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TIMER_DISPATCH_COUNT'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TIMER_PENDING_WAKE_COUNT'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_WAKE_QUEUE_COUNT'

if ($null -in @($ticks, $wake0Tick, $timerEntryCount, $timerDispatchCount, $timerPendingWakeCount, $wakeQueueCount)) {
    throw 'Missing expected task-resume interrupt-timeout stale-timeout fields in probe output.'
}
if ($ticks -lt ($wake0Tick + 8)) { throw "Expected TICKS >= WAKE0_TICK+8. got TICKS=$ticks WAKE0_TICK=$wake0Tick" }
if ($timerEntryCount -ne 0) { throw "Expected TIMER_ENTRY_COUNT=0 after slack. got $timerEntryCount" }
if ($timerDispatchCount -ne 0) { throw "Expected TIMER_DISPATCH_COUNT=0 after slack. got $timerDispatchCount" }
if ($timerPendingWakeCount -ne 1) { throw "Expected TIMER_PENDING_WAKE_COUNT=1 after slack. got $timerPendingWakeCount" }
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1 after slack. got $wakeQueueCount" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_NO_STALE_TIMEOUT_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1'
Write-Output "TICKS=$ticks"
Write-Output "WAKE0_TICK=$wake0Tick"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
