param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-policy-switch-probe-check.ps1"
$schedulerRoundRobinPolicy = 0

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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_RR_RETURN_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-policy-switch probe failed with exit code $probeExitCode"
}

$policy = Extract-IntValue -Text $probeText -Name 'RR_RETURN_POLICY'
$lowRun = Extract-IntValue -Text $probeText -Name 'RR_RETURN_LOW_RUN'
$highRun = Extract-IntValue -Text $probeText -Name 'RR_RETURN_HIGH_RUN'
$highBudgetRemaining = Extract-IntValue -Text $probeText -Name 'RR_RETURN_HIGH_BUDGET_REMAINING'

if ($null -in @($policy, $lowRun, $highRun, $highBudgetRemaining)) {
    throw 'Missing expected round-robin return fields in probe output.'
}
if ($policy -ne $schedulerRoundRobinPolicy) {
    throw "Expected round-robin policy=0 after restoring scheduler policy. got $policy"
}
if ($lowRun -ne 2 -or $highRun -ne 3) {
    throw "Expected round-robin return to hand the next slot to the high task. got low=$lowRun high=$highRun"
}
if ($highBudgetRemaining -ne 3) {
    throw "Expected high task budget remaining to drop to 3 after round-robin return. got $highBudgetRemaining"
}

Write-Output 'BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_RR_RETURN_PROBE=pass'
Write-Output "RR_RETURN_POLICY=$policy"
Write-Output "RR_RETURN_LOW_RUN=$lowRun"
Write-Output "RR_RETURN_HIGH_RUN=$highRun"
Write-Output "RR_RETURN_HIGH_BUDGET_REMAINING=$highBudgetRemaining"
