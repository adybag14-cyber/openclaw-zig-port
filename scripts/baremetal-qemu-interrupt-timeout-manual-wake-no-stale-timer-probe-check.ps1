param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1"
$postWakeSlackTicks = 8

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_NO_STALE_TIMER_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_NO_STALE_TIMER_PROBE_SOURCE=baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout manual-wake probe failed with exit code $probeExitCode"
}

$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_TICKS'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_WAKE0_TICK'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_WAKE_QUEUE_COUNT'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_TIMER_DISPATCH_COUNT'

if ($null -in @($ticks, $wake0Tick, $wakeQueueCount, $timerDispatchCount)) {
    throw 'Missing expected interrupt-timeout manual-wake no-stale-timer fields in probe output.'
}
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1, got $wakeQueueCount" }
if ($timerDispatchCount -ne 0) { throw "Expected TIMER_DISPATCH_COUNT=0, got $timerDispatchCount" }
if ($ticks -lt ($wake0Tick + $postWakeSlackTicks)) { throw "Expected TICKS >= WAKE0_TICK + $postWakeSlackTicks. ticks=$ticks wake0=$wake0Tick" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_NO_STALE_TIMER_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_NO_STALE_TIMER_PROBE_SOURCE=baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1'
Write-Output "TICKS=$ticks"
Write-Output "WAKE0_TICK=$wake0Tick"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
