param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-priority-budget-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-priority-budget probe failed with exit code $probeExitCode"
}

$defaultBudget = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_DEFAULT_BUDGET'
$lowId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_ID'
$highId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_ID'
$lowPriorityBefore = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_PRIORITY_BEFORE'
$highPriorityBefore = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_PRIORITY_BEFORE'
$taskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_TASK_COUNT'
$policy = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_POLICY'
$lowState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_STATE'
$highState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_STATE'

if ($null -in @($defaultBudget, $lowId, $highId, $lowPriorityBefore, $highPriorityBefore, $taskCount, $policy, $lowState, $highState)) {
    throw 'Missing expected scheduler-priority-budget baseline fields in probe output.'
}
if ($defaultBudget -ne 9) { throw "Expected DEFAULT_BUDGET=9. got $defaultBudget" }
if ($lowId -le 0) { throw "Expected LOW_ID > 0. got $lowId" }
if ($highId -le $lowId) { throw "Expected HIGH_ID > LOW_ID. got LOW_ID=$lowId HIGH_ID=$highId" }
if ($lowPriorityBefore -ne 1) { throw "Expected LOW_PRIORITY_BEFORE=1. got $lowPriorityBefore" }
if ($highPriorityBefore -ne 9) { throw "Expected HIGH_PRIORITY_BEFORE=9. got $highPriorityBefore" }
if ($taskCount -ne 2) { throw "Expected TASK_COUNT=2. got $taskCount" }
if ($policy -ne 1) { throw "Expected POLICY=1. got $policy" }
if ($lowState -ne 1 -or $highState -ne 1) { throw "Expected both task states ready. got low=$lowState high=$highState" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_BASELINE_PROBE=pass'
Write-Output "DEFAULT_BUDGET=$defaultBudget"
Write-Output "LOW_ID=$lowId"
Write-Output "HIGH_ID=$highId"
Write-Output "LOW_PRIORITY_BEFORE=$lowPriorityBefore"
Write-Output "HIGH_PRIORITY_BEFORE=$highPriorityBefore"
Write-Output "TASK_COUNT=$taskCount"
Write-Output "POLICY=$policy"
