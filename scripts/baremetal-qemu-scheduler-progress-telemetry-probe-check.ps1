param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_PROGRESS_TELEMETRY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler probe failed with exit code $probeExitCode"
}

$dispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_DISPATCH_COUNT'
$runCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TASK0_RUN_COUNT'
$budgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TASK0_BUDGET_REMAINING'

if ($null -in @($dispatchCount, $runCount, $budgetRemaining)) {
    throw 'Missing expected scheduler progress fields in probe output.'
}
if ($dispatchCount -ne 2) { throw "Expected DISPATCH_COUNT=2. got $dispatchCount" }
if ($runCount -ne 2) { throw "Expected TASK0_RUN_COUNT=2. got $runCount" }
if ($budgetRemaining -ne 6) { throw "Expected TASK0_BUDGET_REMAINING=6. got $budgetRemaining" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_PROGRESS_TELEMETRY_PROBE=pass'
Write-Output "DISPATCH_COUNT=$dispatchCount"
Write-Output "TASK0_RUN_COUNT=$runCount"
Write-Output "TASK0_BUDGET_REMAINING=$budgetRemaining"
