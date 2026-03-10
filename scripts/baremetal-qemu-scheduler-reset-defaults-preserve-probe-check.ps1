param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-reset-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_RESET_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_DEFAULTS_PRESERVE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-reset probe failed with exit code $probeExitCode"
}

$postResetTimeslice = Extract-IntValue -Text $probeText -Name 'POST_RESET_TIMESLICE'
$postResetDefaultBudget = Extract-IntValue -Text $probeText -Name 'POST_RESET_DEFAULT_BUDGET'
$timeslice = Extract-IntValue -Text $probeText -Name 'TIMESLICE'
$defaultBudget = Extract-IntValue -Text $probeText -Name 'DEFAULT_BUDGET'

if ($null -in @($postResetTimeslice, $postResetDefaultBudget, $timeslice, $defaultBudget)) {
    throw 'Missing expected defaults-preserve fields in scheduler-reset probe output.'
}
if ($postResetTimeslice -ne 1) { throw "Expected POST_RESET_TIMESLICE=1. got $postResetTimeslice" }
if ($postResetDefaultBudget -ne 8) { throw "Expected POST_RESET_DEFAULT_BUDGET=8. got $postResetDefaultBudget" }
if ($timeslice -ne 1) { throw "Expected final TIMESLICE=1. got $timeslice" }
if ($defaultBudget -ne 8) { throw "Expected final DEFAULT_BUDGET=8. got $defaultBudget" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_DEFAULTS_PRESERVE_PROBE=pass'
Write-Output "POST_RESET_TIMESLICE=$postResetTimeslice"
Write-Output "POST_RESET_DEFAULT_BUDGET=$postResetDefaultBudget"
Write-Output "TIMESLICE=$timeslice"
Write-Output "DEFAULT_BUDGET=$defaultBudget"
