param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-lifecycle-probe-check.ps1"
$taskStateWaiting = 6
$expectedPriority = 0

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
    Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying task-lifecycle probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_ID'
$taskPriority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_PRIORITY'
$wait1State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_STATE'
$wait1TaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_TASK_COUNT'

if ($null -in @($taskId, $taskPriority, $wait1State, $wait1TaskCount)) {
    throw 'Missing expected wait1 baseline fields in task-lifecycle probe output.'
}
if ($taskId -le 0) { throw "Expected TASK_ID > 0. got $taskId" }
if ($taskPriority -ne $expectedPriority) { throw "Expected TASK_PRIORITY=$expectedPriority. got $taskPriority" }
if ($wait1State -ne $taskStateWaiting) { throw "Expected WAIT1_STATE=$taskStateWaiting. got $wait1State" }
if ($wait1TaskCount -ne 0) { throw "Expected WAIT1_TASK_COUNT=0. got $wait1TaskCount" }

Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_BASELINE_PROBE=pass'
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_ID=$taskId"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_PRIORITY=$taskPriority"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_STATE=$wait1State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_TASK_COUNT=$wait1TaskCount"
