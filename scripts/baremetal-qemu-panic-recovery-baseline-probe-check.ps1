param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-panic-recovery-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_PANIC_RECOVERY_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-recovery probe failed with exit code $probeExitCode"
}

$taskCount = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_RUNNING_SLOT'
$runCount = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_RUN_COUNT'
$budgetRemaining = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_BUDGET_REMAINING'

if ($null -in @($taskCount, $runningSlot, $runCount, $budgetRemaining)) {
    throw 'Missing expected baseline fields in panic-recovery probe output.'
}
if ($taskCount -ne 1) { throw "Expected PRE_PANIC_TASK_COUNT=1. got $taskCount" }
if ($runningSlot -ne 0) { throw "Expected PRE_PANIC_RUNNING_SLOT=0. got $runningSlot" }
if ($runCount -ne 1) { throw "Expected PRE_PANIC_RUN_COUNT=1. got $runCount" }
if ($budgetRemaining -ne 5) { throw "Expected PRE_PANIC_BUDGET_REMAINING=5. got $budgetRemaining" }

Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_BASELINE_PROBE=pass'
Write-Output "PRE_PANIC_TASK_COUNT=$taskCount"
Write-Output "PRE_PANIC_RUNNING_SLOT=$runningSlot"
Write-Output "PRE_PANIC_RUN_COUNT=$runCount"
Write-Output "PRE_PANIC_BUDGET_REMAINING=$budgetRemaining"
