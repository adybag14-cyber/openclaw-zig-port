param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-disable-reenable-probe-check.ps1"
$taskStateWaiting = 6

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
if ($probeText -match 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_DEADLINE_HOLD_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-disable-reenable probe failed with exit code $probeExitCode"
}

$armedTick = Extract-IntValue -Text $probeText -Name 'ARMED_TICK'
$pausedTick = Extract-IntValue -Text $probeText -Name 'PAUSED_TICK'
$pausedEntryCount = Extract-IntValue -Text $probeText -Name 'PAUSED_ENTRY_COUNT'
$pausedTaskState = Extract-IntValue -Text $probeText -Name 'PAUSED_TASK_STATE'

if ($null -in @($armedTick, $pausedTick, $pausedEntryCount, $pausedTaskState)) {
    throw 'Missing expected timer-disable deadline-hold fields in probe output.'
}
if ($pausedTick -le $armedTick) {
    throw "Expected runtime to advance past the original deadline while timers stayed disabled. armed=$armedTick paused=$pausedTick"
}
if ($pausedEntryCount -ne 1) {
    throw "Expected the overdue timer entry to remain armed during the paused window. got $pausedEntryCount"
}
if ($pausedTaskState -ne $taskStateWaiting) {
    throw "Expected task to remain waiting during paused deadline hold. got $pausedTaskState"
}

Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_DEADLINE_HOLD_PROBE=pass'
Write-Output "ARMED_TICK=$armedTick"
Write-Output "PAUSED_TICK=$pausedTick"
Write-Output "PAUSED_ENTRY_COUNT=$pausedEntryCount"
Write-Output "PAUSED_TASK_STATE=$pausedTaskState"
