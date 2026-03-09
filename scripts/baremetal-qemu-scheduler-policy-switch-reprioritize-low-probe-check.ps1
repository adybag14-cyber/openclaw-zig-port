param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-policy-switch-probe-check.ps1"
$boostedLowPriority = 15

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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_REPRIORITIZE_LOW_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-policy-switch probe failed with exit code $probeExitCode"
}

$lowPriority = Extract-IntValue -Text $probeText -Name 'REPRIORITIZED_LOW_PRIORITY'
$lowRun = Extract-IntValue -Text $probeText -Name 'REPRIORITIZED_LOW_RUN'
$highRun = Extract-IntValue -Text $probeText -Name 'REPRIORITIZED_HIGH_RUN'
$lowBudgetRemaining = Extract-IntValue -Text $probeText -Name 'REPRIORITIZED_LOW_BUDGET_REMAINING'

if ($null -in @($lowPriority, $lowRun, $highRun, $lowBudgetRemaining)) {
    throw 'Missing expected reprioritized-low fields in probe output.'
}
if ($lowPriority -ne $boostedLowPriority) {
    throw "Expected boosted low-priority task to move to priority 15. got $lowPriority"
}
if ($lowRun -ne 2 -or $highRun -ne 2) {
    throw "Expected reprioritization to hand the next priority dispatch to the low task. got low=$lowRun high=$highRun"
}
if ($lowBudgetRemaining -ne 4) {
    throw "Expected reprioritized low task budget remaining to drop to 4. got $lowBudgetRemaining"
}

Write-Output 'BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_REPRIORITIZE_LOW_PROBE=pass'
Write-Output "REPRIORITIZED_LOW_PRIORITY=$lowPriority"
Write-Output "REPRIORITIZED_LOW_RUN=$lowRun"
Write-Output "REPRIORITIZED_HIGH_RUN=$highRun"
Write-Output "REPRIORITIZED_LOW_BUDGET_REMAINING=$lowBudgetRemaining"
