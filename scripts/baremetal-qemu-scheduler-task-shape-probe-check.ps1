param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_TASK_SHAPE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TASK0_ID'
$taskState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TASK0_STATE'
$taskPriority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TASK0_PRIORITY'
$taskBudget = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TASK0_BUDGET'

if ($null -in @($taskId, $taskState, $taskPriority, $taskBudget)) {
    throw 'Missing expected scheduler task-shape fields in probe output.'
}
if ($taskId -ne 1) { throw "Expected TASK0_ID=1. got $taskId" }
if ($taskState -ne 1) { throw "Expected TASK0_STATE=1. got $taskState" }
if ($taskPriority -ne 5) { throw "Expected TASK0_PRIORITY=5. got $taskPriority" }
if ($taskBudget -ne 12) { throw "Expected TASK0_BUDGET=12. got $taskBudget" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_TASK_SHAPE_PROBE=pass'
Write-Output "TASK0_ID=$taskId"
Write-Output "TASK0_STATE=$taskState"
Write-Output "TASK0_PRIORITY=$taskPriority"
Write-Output "TASK0_BUDGET=$taskBudget"
