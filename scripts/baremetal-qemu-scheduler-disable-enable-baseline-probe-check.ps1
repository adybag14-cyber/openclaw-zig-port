param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-disable-enable-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-disable-enable probe failed with exit code $probeExitCode"
}

$preEnabled = Extract-IntValue -Text $probeText -Name 'PRE_ENABLED'
$preDispatch = Extract-IntValue -Text $probeText -Name 'PRE_DISPATCH_COUNT'
$preRun = Extract-IntValue -Text $probeText -Name 'PRE_RUN_COUNT'
$preBudget = Extract-IntValue -Text $probeText -Name 'PRE_BUDGET_REMAINING'

if ($null -in @($preEnabled, $preDispatch, $preRun, $preBudget)) {
    throw 'Missing expected baseline fields in scheduler-disable-enable probe output.'
}
if ($preEnabled -ne 1) { throw "Expected PRE_ENABLED=1. got $preEnabled" }
if ($preDispatch -ne 1) { throw "Expected PRE_DISPATCH_COUNT=1. got $preDispatch" }
if ($preRun -ne 1) { throw "Expected PRE_RUN_COUNT=1. got $preRun" }
if ($preBudget -ne 4) { throw "Expected PRE_BUDGET_REMAINING=4. got $preBudget" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_BASELINE_PROBE=pass'
Write-Output "PRE_ENABLED=$preEnabled"
Write-Output "PRE_DISPATCH_COUNT=$preDispatch"
Write-Output "PRE_RUN_COUNT=$preRun"
Write-Output "PRE_BUDGET_REMAINING=$preBudget"