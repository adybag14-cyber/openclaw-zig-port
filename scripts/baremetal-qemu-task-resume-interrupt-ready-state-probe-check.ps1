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
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_READY_STATE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_READY_STATE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume interrupt probe failed with exit code $probeExitCode"
}

$schedTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_SCHED_TASK_COUNT'
$task0Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_ID'
$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_STATE'
$task0Priority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_PRIORITY'
$task0RunCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_RUN_COUNT'
$task0Budget = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_BUDGET'
$task0BudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TASK0_BUDGET_REMAINING'
$timerEnabled = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_PROBE_TIMER_ENABLED'

if ($null -in @($schedTaskCount, $task0Id, $task0State, $task0Priority, $task0RunCount, $task0Budget, $task0BudgetRemaining, $timerEnabled)) {
    throw 'Missing expected task-resume interrupt ready-state fields in probe output.'
}
if ($schedTaskCount -ne 1) { throw "Expected SCHED_TASK_COUNT=1. got $schedTaskCount" }
if ($task0Id -le 0) { throw "Expected TASK0_ID>0. got $task0Id" }
if ($task0State -ne 1) { throw "Expected TASK0_STATE=1. got $task0State" }
if ($task0Priority -ne 0) { throw "Expected TASK0_PRIORITY=0. got $task0Priority" }
if ($task0RunCount -ne 0) { throw "Expected TASK0_RUN_COUNT=0. got $task0RunCount" }
if ($task0Budget -ne 5) { throw "Expected TASK0_BUDGET=5. got $task0Budget" }
if ($task0BudgetRemaining -ne 5) { throw "Expected TASK0_BUDGET_REMAINING=5. got $task0BudgetRemaining" }
if ($timerEnabled -ne 1) { throw "Expected TIMER_ENABLED=1. got $timerEnabled" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_READY_STATE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_READY_STATE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-probe-check.ps1'
Write-Output "SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "TASK0_ID=$task0Id"
Write-Output "TASK0_STATE=$task0State"
Write-Output "TASK0_PRIORITY=$task0Priority"
Write-Output "TASK0_RUN_COUNT=$task0RunCount"
Write-Output "TASK0_BUDGET=$task0Budget"
Write-Output "TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "TIMER_ENABLED=$timerEnabled"
