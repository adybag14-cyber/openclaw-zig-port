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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_DEFAULT_BUDGET_INHERITANCE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-priority-budget probe failed with exit code $probeExitCode"
}

$lowBudgetTicks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_BUDGET_TICKS'
$lowBudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_BUDGET_REMAINING'
$highBudgetTicks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_BUDGET_TICKS'
$highBudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_BUDGET_REMAINING'

if ($null -in @($lowBudgetTicks, $lowBudgetRemaining, $highBudgetTicks, $highBudgetRemaining)) {
    throw 'Missing expected scheduler-priority-budget inheritance fields in probe output.'
}
if ($lowBudgetTicks -ne 9 -or $lowBudgetRemaining -ne 9) {
    throw "Expected low task to inherit default budget 9/9. got ticks=$lowBudgetTicks remaining=$lowBudgetRemaining"
}
if ($highBudgetTicks -ne 6 -or $highBudgetRemaining -ne 6) {
    throw "Expected high task explicit budget 6/6. got ticks=$highBudgetTicks remaining=$highBudgetRemaining"
}

Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_DEFAULT_BUDGET_INHERITANCE_PROBE=pass'
Write-Output "LOW_BUDGET_TICKS=$lowBudgetTicks"
Write-Output "LOW_BUDGET_REMAINING=$lowBudgetRemaining"
Write-Output "HIGH_BUDGET_TICKS=$highBudgetTicks"
Write-Output "HIGH_BUDGET_REMAINING=$highBudgetRemaining"
