param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-round-robin-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_DISPATCH_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-round-robin probe failed with exit code $probeExitCode"
}

$firstRunAfterFirst = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_RUN_AFTER_FIRST'
$secondRunAfterFirst = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_RUN_AFTER_FIRST'
$firstBudgetAfterFirst = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_BUDGET_AFTER_FIRST'

if ($null -in @($firstRunAfterFirst, $secondRunAfterFirst, $firstBudgetAfterFirst)) {
    throw 'Missing expected first-dispatch fields in scheduler-round-robin probe output.'
}
if ($firstRunAfterFirst -ne 1) { throw "Expected FIRST_RUN_AFTER_FIRST=1. got $firstRunAfterFirst" }
if ($secondRunAfterFirst -ne 0) { throw "Expected SECOND_RUN_AFTER_FIRST=0. got $secondRunAfterFirst" }
if ($firstBudgetAfterFirst -ne 3) { throw "Expected FIRST_BUDGET_AFTER_FIRST=3. got $firstBudgetAfterFirst" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_DISPATCH_PROBE=pass'
Write-Output "FIRST_RUN_AFTER_FIRST=$firstRunAfterFirst"
Write-Output "SECOND_RUN_AFTER_FIRST=$secondRunAfterFirst"
Write-Output "FIRST_BUDGET_AFTER_FIRST=$firstBudgetAfterFirst"
