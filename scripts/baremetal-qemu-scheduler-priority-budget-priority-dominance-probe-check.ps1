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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PRIORITY_DOMINANCE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-priority-budget probe failed with exit code $probeExitCode"
}

$policy = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_POLICY'
$lowRunBefore = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_RUN_BEFORE'
$highRunBefore = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_RUN_BEFORE'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_DISPATCH_COUNT'

if ($null -in @($policy, $lowRunBefore, $highRunBefore, $dispatchCount)) {
    throw 'Missing expected scheduler-priority-budget dominance fields in probe output.'
}
if ($policy -ne 1) { throw "Expected POLICY=1. got $policy" }
if ($lowRunBefore -ne 0) { throw "Expected LOW_RUN_BEFORE=0. got $lowRunBefore" }
if ($highRunBefore -lt 1) { throw "Expected HIGH_RUN_BEFORE >= 1. got $highRunBefore" }
if ($dispatchCount -lt 2) { throw "Expected DISPATCH_COUNT >= 2. got $dispatchCount" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PRIORITY_DOMINANCE_PROBE=pass'
Write-Output "POLICY=$policy"
Write-Output "LOW_RUN_BEFORE=$lowRunBefore"
Write-Output "HIGH_RUN_BEFORE=$highRunBefore"
Write-Output "DISPATCH_COUNT=$dispatchCount"
