param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-disable-enable-probe-check.ps1"
$schedulerNoSlot = 255

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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_DISABLED_FREEZE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-disable-enable probe failed with exit code $probeExitCode"
}

$disabledEnabled = Extract-IntValue -Text $probeText -Name 'DISABLED_ENABLED'
$disabledSlot = Extract-IntValue -Text $probeText -Name 'DISABLED_RUNNING_SLOT'
$disabledDispatch = Extract-IntValue -Text $probeText -Name 'DISABLED_DISPATCH_COUNT'
$disabledRun = Extract-IntValue -Text $probeText -Name 'DISABLED_RUN_COUNT'
$disabledBudget = Extract-IntValue -Text $probeText -Name 'DISABLED_BUDGET_REMAINING'

if ($null -in @($disabledEnabled, $disabledSlot, $disabledDispatch, $disabledRun, $disabledBudget)) {
    throw 'Missing expected disabled-state fields in scheduler-disable-enable probe output.'
}
if ($disabledEnabled -ne 0) { throw "Expected DISABLED_ENABLED=0. got $disabledEnabled" }
if ($disabledSlot -ne $schedulerNoSlot) { throw "Expected DISABLED_RUNNING_SLOT=255. got $disabledSlot" }
if ($disabledDispatch -ne 1) { throw "Expected DISABLED_DISPATCH_COUNT=1. got $disabledDispatch" }
if ($disabledRun -ne 1) { throw "Expected DISABLED_RUN_COUNT=1. got $disabledRun" }
if ($disabledBudget -ne 4) { throw "Expected DISABLED_BUDGET_REMAINING=4. got $disabledBudget" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_DISABLED_FREEZE_PROBE=pass'
Write-Output "DISABLED_ENABLED=$disabledEnabled"
Write-Output "DISABLED_RUNNING_SLOT=$disabledSlot"
Write-Output "DISABLED_DISPATCH_COUNT=$disabledDispatch"
Write-Output "DISABLED_RUN_COUNT=$disabledRun"
Write-Output "DISABLED_BUDGET_REMAINING=$disabledBudget"