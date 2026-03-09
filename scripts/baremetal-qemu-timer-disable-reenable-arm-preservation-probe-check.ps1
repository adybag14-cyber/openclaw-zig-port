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
    Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_ARM_PRESERVATION_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-disable-reenable probe failed with exit code $probeExitCode"
}

$armedTick = Extract-IntValue -Text $probeText -Name 'ARMED_TICK'
$armedTaskState = Extract-IntValue -Text $probeText -Name 'ARMED_TASK_STATE'
$disabledTick = Extract-IntValue -Text $probeText -Name 'DISABLED_TICK'

if ($null -in @($armedTick, $armedTaskState, $disabledTick)) {
    throw 'Missing expected timer-disable arm-preservation fields in probe output.'
}
if ($armedTick -le 0) {
    throw "Expected a positive armed tick before disable. got $armedTick"
}
if ($armedTaskState -ne $taskStateWaiting) {
    throw "Expected the armed task to be waiting(6) before disable. got $armedTaskState"
}
if ($disabledTick -gt $armedTick) {
    throw "Expected disable to occur no later than the original fire tick. armed=$armedTick disabled=$disabledTick"
}

Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_ARM_PRESERVATION_PROBE=pass'
Write-Output "ARMED_TICK=$armedTick"
Write-Output "ARMED_TASK_STATE=$armedTaskState"
Write-Output "DISABLED_TICK=$disabledTick"
