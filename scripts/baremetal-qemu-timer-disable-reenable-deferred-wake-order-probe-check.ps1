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
    Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_DEFERRED_WAKE_ORDER_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-disable-reenable probe failed with exit code $probeExitCode"
}

$pausedTick = Extract-IntValue -Text $probeText -Name 'PAUSED_TICK'
$postWakeTick = Extract-IntValue -Text $probeText -Name 'POST_WAKE_TICK'

if ($null -in @($pausedTick, $postWakeTick)) {
    throw 'Missing expected timer-disable deferred-wake ordering fields in probe output.'
}
if ($postWakeTick -le $pausedTick) {
    throw "Expected the overdue wake to appear only after timer re-enable. paused=$pausedTick postWake=$postWakeTick"
}

Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_DEFERRED_WAKE_ORDER_PROBE=pass'
Write-Output "PAUSED_TICK=$pausedTick"
Write-Output "POST_WAKE_TICK=$postWakeTick"
