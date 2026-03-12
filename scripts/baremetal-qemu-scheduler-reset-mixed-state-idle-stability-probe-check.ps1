param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-scheduler-reset-mixed-state-probe-check.ps1'

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_IDLE_STABILITY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-reset mixed-state probe failed with exit code $probeExitCode"
}

$afterIdleWakeCount = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_WAKE_COUNT'
$afterIdleTimerCount = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_TIMER_COUNT'

if ($null -in @($afterIdleWakeCount, $afterIdleTimerCount)) {
    throw 'Missing expected scheduler-reset mixed-state idle fields in probe output.'
}
if ($afterIdleWakeCount -ne 0) { throw "Expected AFTER_IDLE_WAKE_COUNT=0. got $afterIdleWakeCount" }
if ($afterIdleTimerCount -ne 0) { throw "Expected AFTER_IDLE_TIMER_COUNT=0. got $afterIdleTimerCount" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_IDLE_STABILITY_PROBE=pass'
Write-Output "AFTER_IDLE_WAKE_COUNT=$afterIdleWakeCount"
Write-Output "AFTER_IDLE_TIMER_COUNT=$afterIdleTimerCount"
