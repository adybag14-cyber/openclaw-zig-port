param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-disable-enable-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_FINAL_TASK_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-disable-enable probe failed with exit code $probeExitCode"
}

$taskCount = Extract-IntValue -Text $probeText -Name 'TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'RUNNING_SLOT'
$taskId = Extract-IntValue -Text $probeText -Name 'TASK0_ID'
$taskState = Extract-IntValue -Text $probeText -Name 'TASK0_STATE'
$taskPriority = Extract-IntValue -Text $probeText -Name 'TASK0_PRIORITY'
$taskRunCount = Extract-IntValue -Text $probeText -Name 'TASK0_RUN_COUNT'
$taskBudget = Extract-IntValue -Text $probeText -Name 'TASK0_BUDGET'
$taskBudgetRemaining = Extract-IntValue -Text $probeText -Name 'TASK0_BUDGET_REMAINING'
$ticks = Extract-IntValue -Text $probeText -Name 'TICKS'

if ($null -in @($taskCount, $runningSlot, $taskId, $taskState, $taskPriority, $taskRunCount, $taskBudget, $taskBudgetRemaining, $ticks)) {
    throw 'Missing expected final task-state fields in scheduler-disable-enable probe output.'
}
if ($taskCount -ne 1) { throw "Expected TASK_COUNT=1. got $taskCount" }
if ($runningSlot -ne 0) { throw "Expected RUNNING_SLOT=0. got $runningSlot" }
if ($taskId -ne 1) { throw "Expected TASK0_ID=1. got $taskId" }
if ($taskState -ne 1) { throw "Expected TASK0_STATE=1. got $taskState" }
if ($taskPriority -ne 2) { throw "Expected TASK0_PRIORITY=2. got $taskPriority" }
if ($taskRunCount -ne 2) { throw "Expected TASK0_RUN_COUNT=2. got $taskRunCount" }
if ($taskBudget -ne 5) { throw "Expected TASK0_BUDGET=5. got $taskBudget" }
if ($taskBudgetRemaining -ne 3) { throw "Expected TASK0_BUDGET_REMAINING=3. got $taskBudgetRemaining" }
if ($ticks -lt 5) { throw "Expected TICKS>=5. got $ticks" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_FINAL_TASK_STATE_PROBE=pass'
Write-Output "TASK_COUNT=$taskCount"
Write-Output "RUNNING_SLOT=$runningSlot"
Write-Output "TASK0_ID=$taskId"
Write-Output "TASK0_STATE=$taskState"
Write-Output "TASK0_PRIORITY=$taskPriority"
Write-Output "TASK0_RUN_COUNT=$taskRunCount"
Write-Output "TASK0_BUDGET=$taskBudget"
Write-Output "TASK0_BUDGET_REMAINING=$taskBudgetRemaining"
Write-Output "TICKS=$ticks"