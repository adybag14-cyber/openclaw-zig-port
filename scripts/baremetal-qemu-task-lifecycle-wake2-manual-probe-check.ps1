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
    Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_MANUAL_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying task-lifecycle probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_ID'
$wake2QueueLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_QUEUE_LEN'
$wake2State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_STATE'
$wake2Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_REASON'
$wake2TaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_TASK_ID'

if ($null -in @($taskId, $wake2QueueLen, $wake2State, $wake2Reason, $wake2TaskId)) {
    throw 'Missing expected wake2 fields in task-lifecycle probe output.'
}
if ($wake2QueueLen -ne 2) { throw "Expected WAKE2_QUEUE_LEN=2. got $wake2QueueLen" }
if ($wake2State -ne $taskStateReady) { throw "Expected WAKE2_STATE=$taskStateReady. got $wake2State" }
if ($wake2Reason -ne $wakeReasonManual) { throw "Expected WAKE2_REASON=$wakeReasonManual. got $wake2Reason" }
if ($wake2TaskId -ne $taskId) { throw "Expected WAKE2_TASK_ID=$taskId. got $wake2TaskId" }

Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_MANUAL_PROBE=pass'
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_QUEUE_LEN=$wake2QueueLen"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_STATE=$wake2State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_REASON=$wake2Reason"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_TASK_ID=$wake2TaskId"
