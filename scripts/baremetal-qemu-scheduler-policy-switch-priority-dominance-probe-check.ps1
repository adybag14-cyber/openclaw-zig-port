param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-policy-switch-probe-check.ps1"
$schedulerPriorityPolicy = 1

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PRIORITY_DOMINANCE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-policy-switch probe failed with exit code $probeExitCode"
}

$policy = Extract-IntValue -Text $probeText -Name 'PRIORITY_POLICY'
$lowRun = Extract-IntValue -Text $probeText -Name 'PRIORITY_LOW_RUN'
$highRun = Extract-IntValue -Text $probeText -Name 'PRIORITY_HIGH_RUN'
$highBudgetRemaining = Extract-IntValue -Text $probeText -Name 'PRIORITY_HIGH_BUDGET_REMAINING'

if ($null -in @($policy, $lowRun, $highRun, $highBudgetRemaining)) {
    throw 'Missing expected priority-dominance fields in probe output.'
}
if ($policy -ne $schedulerPriorityPolicy) {
    throw "Expected priority policy=1 after switch. got $policy"
}
if ($lowRun -ne 1 -or $highRun -ne 2) {
    throw "Expected priority switch to favor the high-priority task. got low=$lowRun high=$highRun"
}
if ($highBudgetRemaining -ne 4) {
    throw "Expected high-priority task budget remaining to drop to 4 after the extra dispatch. got $highBudgetRemaining"
}

Write-Output 'BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PRIORITY_DOMINANCE_PROBE=pass'
Write-Output "PRIORITY_POLICY=$policy"
Write-Output "PRIORITY_LOW_RUN=$lowRun"
Write-Output "PRIORITY_HIGH_RUN=$highRun"
Write-Output "PRIORITY_HIGH_BUDGET_REMAINING=$highBudgetRemaining"
