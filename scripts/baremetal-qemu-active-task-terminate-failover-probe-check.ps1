param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-active-task-terminate-probe-check.ps1"
$taskStateTerminated = 4

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
    Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_FAILOVER_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying active-task terminate probe failed with exit code $probeExitCode"
}

$taskCount = Extract-IntValue -Text $probeText -Name 'POST_TERMINATE_TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'POST_TERMINATE_RUNNING_SLOT'
$lowRun = Extract-IntValue -Text $probeText -Name 'POST_TERMINATE_LOW_RUN'
$lowBudget = Extract-IntValue -Text $probeText -Name 'POST_TERMINATE_LOW_BUDGET_REMAINING'
$highState = Extract-IntValue -Text $probeText -Name 'POST_TERMINATE_HIGH_STATE'

if ($null -in @($taskCount, $runningSlot, $lowRun, $lowBudget, $highState)) {
    throw 'Missing expected failover fields in active-task terminate probe output.'
}
if ($taskCount -ne 1) { throw "Expected POST_TERMINATE_TASK_COUNT=1. got $taskCount" }
if ($runningSlot -ne 0) { throw "Expected POST_TERMINATE_RUNNING_SLOT=0. got $runningSlot" }
if ($lowRun -ne 1) { throw "Expected POST_TERMINATE_LOW_RUN=1. got $lowRun" }
if ($lowBudget -ne 5) { throw "Expected POST_TERMINATE_LOW_BUDGET_REMAINING=5. got $lowBudget" }
if ($highState -ne $taskStateTerminated) { throw "Expected POST_TERMINATE_HIGH_STATE=4. got $highState" }

Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_FAILOVER_PROBE=pass'
Write-Output "POST_TERMINATE_TASK_COUNT=$taskCount"
Write-Output "POST_TERMINATE_RUNNING_SLOT=$runningSlot"
Write-Output "POST_TERMINATE_LOW_RUN=$lowRun"
Write-Output "POST_TERMINATE_LOW_BUDGET_REMAINING=$lowBudget"
Write-Output "POST_TERMINATE_HIGH_STATE=$highState"
