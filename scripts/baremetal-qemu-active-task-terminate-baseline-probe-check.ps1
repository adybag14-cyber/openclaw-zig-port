param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-active-task-terminate-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying active-task terminate probe failed with exit code $probeExitCode"
}

$taskCount = Extract-IntValue -Text $probeText -Name 'PRE_TERMINATE_TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'PRE_TERMINATE_RUNNING_SLOT'
$lowRun = Extract-IntValue -Text $probeText -Name 'PRE_TERMINATE_LOW_RUN'
$highRun = Extract-IntValue -Text $probeText -Name 'PRE_TERMINATE_HIGH_RUN'
$highBudget = Extract-IntValue -Text $probeText -Name 'PRE_TERMINATE_HIGH_BUDGET_REMAINING'

if ($null -in @($taskCount, $runningSlot, $lowRun, $highRun, $highBudget)) {
    throw 'Missing expected baseline fields in active-task terminate probe output.'
}
if ($taskCount -ne 2) { throw "Expected PRE_TERMINATE_TASK_COUNT=2. got $taskCount" }
if ($runningSlot -ne 1) { throw "Expected PRE_TERMINATE_RUNNING_SLOT=1. got $runningSlot" }
if ($lowRun -ne 0) { throw "Expected PRE_TERMINATE_LOW_RUN=0. got $lowRun" }
if ($highRun -ne 1) { throw "Expected PRE_TERMINATE_HIGH_RUN=1. got $highRun" }
if ($highBudget -ne 5) { throw "Expected PRE_TERMINATE_HIGH_BUDGET_REMAINING=5. got $highBudget" }

Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_BASELINE_PROBE=pass'
Write-Output "PRE_TERMINATE_TASK_COUNT=$taskCount"
Write-Output "PRE_TERMINATE_RUNNING_SLOT=$runningSlot"
Write-Output "PRE_TERMINATE_LOW_RUN=$lowRun"
Write-Output "PRE_TERMINATE_HIGH_RUN=$highRun"
Write-Output "PRE_TERMINATE_HIGH_BUDGET_REMAINING=$highBudget"
