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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_DISPATCH_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-round-robin probe failed with exit code $probeExitCode"
}

$firstRunAfterSecond = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_RUN_AFTER_SECOND'
$secondRunAfterSecond = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_RUN_AFTER_SECOND'
$secondBudgetAfterSecond = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_BUDGET_AFTER_SECOND'

if ($null -in @($firstRunAfterSecond, $secondRunAfterSecond, $secondBudgetAfterSecond)) {
    throw 'Missing expected second-dispatch fields in scheduler-round-robin probe output.'
}
if ($firstRunAfterSecond -ne 1) { throw "Expected FIRST_RUN_AFTER_SECOND=1. got $firstRunAfterSecond" }
if ($secondRunAfterSecond -ne 1) { throw "Expected SECOND_RUN_AFTER_SECOND=1. got $secondRunAfterSecond" }
if ($secondBudgetAfterSecond -ne 3) { throw "Expected SECOND_BUDGET_AFTER_SECOND=3. got $secondBudgetAfterSecond" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_DISPATCH_PROBE=pass'
Write-Output "FIRST_RUN_AFTER_SECOND=$firstRunAfterSecond"
Write-Output "SECOND_RUN_AFTER_SECOND=$secondRunAfterSecond"
Write-Output "SECOND_BUDGET_AFTER_SECOND=$secondBudgetAfterSecond"
