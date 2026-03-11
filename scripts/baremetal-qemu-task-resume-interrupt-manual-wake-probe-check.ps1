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
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_MANUAL_WAKE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_MANUAL_WAKE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume interrupt probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_ID'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAKE_QUEUE_COUNT'
$wakeTaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAKE0_TASK_ID'
$wakeTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAKE0_TIMER_ID'
$wakeReason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAKE0_REASON'
$wakeVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_WAKE0_VECTOR'

if ($null -in @($taskId, $wakeQueueCount, $wakeTaskId, $wakeTimerId, $wakeReason, $wakeVector)) {
    throw 'Missing expected task-resume interrupt manual-wake fields in probe output.'
}
if ($taskId -le 0) { throw "Expected TASK0_ID>0. got $taskId" }
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1. got $wakeQueueCount" }
if ($wakeTaskId -ne $taskId) { throw "Expected WAKE0_TASK_ID=$taskId. got $wakeTaskId" }
if ($wakeTimerId -ne 0) { throw "Expected WAKE0_TIMER_ID=0 for manual wake. got $wakeTimerId" }
if ($wakeReason -ne 3) { throw "Expected WAKE0_REASON=3 for manual wake. got $wakeReason" }
if ($wakeVector -ne 0) { throw "Expected WAKE0_VECTOR=0 for manual wake. got $wakeVector" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_MANUAL_WAKE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_MANUAL_WAKE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
Write-Output "TASK0_ID=$taskId"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_TASK_ID=$wakeTaskId"
Write-Output "WAKE0_TIMER_ID=$wakeTimerId"
Write-Output "WAKE0_REASON=$wakeReason"
Write-Output "WAKE0_VECTOR=$wakeVector"
