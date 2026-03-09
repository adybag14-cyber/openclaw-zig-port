param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-lifecycle-probe-check.ps1"
$taskStateReady = 1
$wakeReasonManual = 3

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
    Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_MANUAL_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying task-lifecycle probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_ID'
$wake1QueueLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_QUEUE_LEN'
$wake1State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_STATE'
$wake1Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_REASON'
$wake1TaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_TASK_ID'

if ($null -in @($taskId, $wake1QueueLen, $wake1State, $wake1Reason, $wake1TaskId)) {
    throw 'Missing expected wake1 fields in task-lifecycle probe output.'
}
if ($wake1QueueLen -ne 1) { throw "Expected WAKE1_QUEUE_LEN=1. got $wake1QueueLen" }
if ($wake1State -ne $taskStateReady) { throw "Expected WAKE1_STATE=$taskStateReady. got $wake1State" }
if ($wake1Reason -ne $wakeReasonManual) { throw "Expected WAKE1_REASON=$wakeReasonManual. got $wake1Reason" }
if ($wake1TaskId -ne $taskId) { throw "Expected WAKE1_TASK_ID=$taskId. got $wake1TaskId" }

Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_MANUAL_PROBE=pass'
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_QUEUE_LEN=$wake1QueueLen"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_STATE=$wake1State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_REASON=$wake1Reason"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_TASK_ID=$wake1TaskId"
