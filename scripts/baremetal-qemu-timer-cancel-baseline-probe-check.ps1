param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-cancel-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-cancel probe failed with exit code $probeExitCode"
}

$armedTicks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_ARMED_TICKS'
$preCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_ENTRY_COUNT'
$preTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_TIMER0_ID'
$preTimerState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_TIMER0_STATE'
$preTaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_TIMER0_TASK_ID'
$preNextFire = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_TIMER0_NEXT_FIRE_TICK'

if ($null -in @($armedTicks, $preCount, $preTimerId, $preTimerState, $preTaskId, $preNextFire)) {
    throw 'Missing baseline timer-cancel fields.'
}
if ($preCount -ne 1) { throw "Expected PRE_CANCEL_ENTRY_COUNT=1. got $preCount" }
if ($preTimerId -le 0) { throw "Expected PRE_CANCEL_TIMER0_ID>0. got $preTimerId" }
if ($preTimerState -ne 1) { throw "Expected PRE_CANCEL_TIMER0_STATE=1. got $preTimerState" }
if ($preTaskId -ne 1) { throw "Expected PRE_CANCEL_TIMER0_TASK_ID=1. got $preTaskId" }
if ($preNextFire -le $armedTicks) { throw "Expected PRE_CANCEL_TIMER0_NEXT_FIRE_TICK>$armedTicks. got $preNextFire" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_BASELINE_PROBE=pass'
Write-Output "ARMED_TICKS=$armedTicks"
Write-Output "PRE_CANCEL_ENTRY_COUNT=$preCount"
Write-Output "PRE_CANCEL_TIMER0_ID=$preTimerId"
Write-Output "PRE_CANCEL_TIMER0_STATE=$preTimerState"
Write-Output "PRE_CANCEL_TIMER0_TASK_ID=$preTaskId"
Write-Output "PRE_CANCEL_TIMER0_NEXT_FIRE_TICK=$preNextFire"
