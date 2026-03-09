param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-disable-reenable-probe-check.ps1"

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
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_PAUSED_STATE_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-disable-reenable probe failed with exit code $probeExitCode"
}

$armedTaskState = Extract-IntValue -Text $probeText -Name 'ARMED_TASK_STATE'
$pausedTick = Extract-IntValue -Text $probeText -Name 'PAUSED_TICK'
$armedTick = Extract-IntValue -Text $probeText -Name 'ARMED_TICK'
$pausedWakeCount = Extract-IntValue -Text $probeText -Name 'PAUSED_WAKE_COUNT'
$pausedDispatchCount = Extract-IntValue -Text $probeText -Name 'PAUSED_DISPATCH_COUNT'
$pausedEntryCount = Extract-IntValue -Text $probeText -Name 'PAUSED_ENTRY_COUNT'
$pausedTaskState = Extract-IntValue -Text $probeText -Name 'PAUSED_TASK_STATE'

if ($null -in @($armedTaskState, $pausedTick, $armedTick, $pausedWakeCount, $pausedDispatchCount, $pausedEntryCount, $pausedTaskState)) {
    throw 'Missing expected timer-disable paused-state fields in probe output.'
}
if ($armedTaskState -ne 6) {
    throw "Expected armed task state to be waiting(6). got $armedTaskState"
}
if ($pausedTick -le $armedTick) {
    throw "Expected paused tick to move past armed tick while timers stayed disabled. armed=$armedTick paused=$pausedTick"
}
if ($pausedWakeCount -ne 0) {
    throw "Expected no wake queue entries while timers were disabled. got $pausedWakeCount"
}
if ($pausedDispatchCount -ne 0) {
    throw "Expected no timer dispatch while timers were disabled. got $pausedDispatchCount"
}
if ($pausedEntryCount -ne 1) {
    throw "Expected the armed timer entry to remain present while paused. got $pausedEntryCount"
}
if ($pausedTaskState -ne 6) {
    throw "Expected the task to remain waiting while paused. got $pausedTaskState"
}

Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_PAUSED_STATE_PROBE=pass'
Write-Output "ARMED_TICK=$armedTick"
Write-Output "PAUSED_TICK=$pausedTick"
Write-Output "PAUSED_WAKE_COUNT=$pausedWakeCount"
Write-Output "PAUSED_DISPATCH_COUNT=$pausedDispatchCount"
Write-Output "PAUSED_ENTRY_COUNT=$pausedEntryCount"
Write-Output "PAUSED_TASK_STATE=$pausedTaskState"
