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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_IDLE_PRESERVE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-disable-enable probe failed with exit code $probeExitCode"
}

$idleTicks = Extract-IntValue -Text $probeText -Name 'IDLE_DISABLED_TICKS'
$idleDispatch = Extract-IntValue -Text $probeText -Name 'IDLE_DISABLED_DISPATCH_COUNT'
$idleRun = Extract-IntValue -Text $probeText -Name 'IDLE_DISABLED_RUN_COUNT'
$idleBudget = Extract-IntValue -Text $probeText -Name 'IDLE_DISABLED_BUDGET_REMAINING'

if ($null -in @($idleTicks, $idleDispatch, $idleRun, $idleBudget)) {
    throw 'Missing expected idle-disabled fields in scheduler-disable-enable probe output.'
}
if ($idleTicks -lt 5) { throw "Expected IDLE_DISABLED_TICKS>=5. got $idleTicks" }
if ($idleDispatch -ne 1) { throw "Expected IDLE_DISABLED_DISPATCH_COUNT=1. got $idleDispatch" }
if ($idleRun -ne 1) { throw "Expected IDLE_DISABLED_RUN_COUNT=1. got $idleRun" }
if ($idleBudget -ne 4) { throw "Expected IDLE_DISABLED_BUDGET_REMAINING=4. got $idleBudget" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_IDLE_PRESERVE_PROBE=pass'
Write-Output "IDLE_DISABLED_TICKS=$idleTicks"
Write-Output "IDLE_DISABLED_DISPATCH_COUNT=$idleDispatch"
Write-Output "IDLE_DISABLED_RUN_COUNT=$idleRun"
Write-Output "IDLE_DISABLED_BUDGET_REMAINING=$idleBudget"