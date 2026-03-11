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
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_READY_STATE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_READY_STATE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume interrupt-timeout probe failed with exit code $probeExitCode"
}

$schedTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_SCHED_TASK_COUNT'
$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TASK0_ID'
$taskState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TASK0_STATE'
$taskPriority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TASK0_PRIORITY'
$taskRunCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TASK0_RUN_COUNT'
$taskBudget = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TASK0_BUDGET'
$taskBudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TASK0_BUDGET_REMAINING'
$timerEnabled = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TIMER_ENABLED'

if ($null -in @($schedTaskCount, $taskId, $taskState, $taskPriority, $taskRunCount, $taskBudget, $taskBudgetRemaining, $timerEnabled)) {
    throw 'Missing expected task-resume interrupt-timeout ready-state fields in probe output.'
}
if ($schedTaskCount -ne 1) { throw "Expected SCHED_TASK_COUNT=1. got $schedTaskCount" }
if ($taskId -le 0) { throw "Expected TASK0_ID>0. got $taskId" }
if ($taskState -ne 1) { throw "Expected TASK0_STATE=1. got $taskState" }
if ($taskPriority -ne 0) { throw "Expected TASK0_PRIORITY=0. got $taskPriority" }
if ($taskRunCount -ne 0) { throw "Expected TASK0_RUN_COUNT=0. got $taskRunCount" }
if ($taskBudget -ne 5) { throw "Expected TASK0_BUDGET=5. got $taskBudget" }
if ($taskBudgetRemaining -ne 5) { throw "Expected TASK0_BUDGET_REMAINING=5. got $taskBudgetRemaining" }
if ($timerEnabled -ne 1) { throw "Expected TIMER_ENABLED=1. got $timerEnabled" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_READY_STATE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_READY_STATE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1'
Write-Output "SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "TASK0_ID=$taskId"
Write-Output "TASK0_STATE=$taskState"
Write-Output "TASK0_PRIORITY=$taskPriority"
Write-Output "TASK0_RUN_COUNT=$taskRunCount"
Write-Output "TASK0_BUDGET=$taskBudget"
Write-Output "TASK0_BUDGET_REMAINING=$taskBudgetRemaining"
Write-Output "TIMER_ENABLED=$timerEnabled"
