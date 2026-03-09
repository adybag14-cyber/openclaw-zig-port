param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-lifecycle-probe-check.ps1"
$taskStateTerminated = 4
$schedulerWakeTaskOpcode = 45
$resultNotFound = -2

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_TASK_LIFECYCLE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_REJECTED_WAKE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying task-lifecycle probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_LAST_RESULT'
$terminateState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_STATE'
$terminateTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_TASK_COUNT'
$rejectedWakeQueueLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_REJECTED_WAKE_QUEUE_LEN'

if ($null -in @($ack, $lastOpcode, $lastResult, $terminateState, $terminateTaskCount, $rejectedWakeQueueLen)) {
    throw 'Missing expected terminate/rejected-wake fields in task-lifecycle probe output.'
}
if ($ack -ne 10) { throw "Expected ACK=10. got $ack" }
if ($lastOpcode -ne $schedulerWakeTaskOpcode) { throw "Expected LAST_OPCODE=$schedulerWakeTaskOpcode. got $lastOpcode" }
if ($lastResult -ne $resultNotFound) { throw "Expected LAST_RESULT=$resultNotFound. got $lastResult" }
if ($terminateState -ne $taskStateTerminated) { throw "Expected TERMINATE_STATE=$taskStateTerminated. got $terminateState" }
if ($terminateTaskCount -ne 0) { throw "Expected TERMINATE_TASK_COUNT=0. got $terminateTaskCount" }
if ($rejectedWakeQueueLen -ne 0) { throw "Expected REJECTED_WAKE_QUEUE_LEN=0. got $rejectedWakeQueueLen" }

Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_REJECTED_WAKE_PROBE=pass'
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_STATE=$terminateState"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_TASK_COUNT=$terminateTaskCount"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_REJECTED_WAKE_QUEUE_LEN=$rejectedWakeQueueLen"
