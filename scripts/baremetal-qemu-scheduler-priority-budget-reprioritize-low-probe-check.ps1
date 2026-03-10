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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_REPRIORITIZE_LOW_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-priority-budget probe failed with exit code $probeExitCode"
}

$lowPriorityAfter = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_PRIORITY_AFTER'
$lowRunAfter = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_RUN_AFTER'
$highRunBefore = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_RUN_BEFORE'
$highRunAfter = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_RUN_AFTER'

if ($null -in @($lowPriorityAfter, $lowRunAfter, $highRunBefore, $highRunAfter)) {
    throw 'Missing expected scheduler-priority-budget reprioritize fields in probe output.'
}
if ($lowPriorityAfter -ne 15) { throw "Expected LOW_PRIORITY_AFTER=15. got $lowPriorityAfter" }
if ($lowRunAfter -lt 1) { throw "Expected LOW_RUN_AFTER >= 1. got $lowRunAfter" }
if ($highRunBefore -lt 1) { throw "Expected HIGH_RUN_BEFORE >= 1. got $highRunBefore" }
if ($highRunAfter -lt $highRunBefore) { throw "Expected HIGH_RUN_AFTER >= HIGH_RUN_BEFORE. got before=$highRunBefore after=$highRunAfter" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_REPRIORITIZE_LOW_PROBE=pass'
Write-Output "LOW_PRIORITY_AFTER=$lowPriorityAfter"
Write-Output "LOW_RUN_AFTER=$lowRunAfter"
Write-Output "HIGH_RUN_BEFORE=$highRunBefore"
Write-Output "HIGH_RUN_AFTER=$highRunAfter"
