param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1"

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
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_TELEMETRY_PRESERVE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_TELEMETRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout manual-wake probe failed with exit code $probeExitCode"
}

$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_INTERRUPT_COUNT'
$lastInterruptVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_LAST_INTERRUPT_VECTOR'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_TIMER_PENDING_WAKE_COUNT'
$timerLastInterruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_TIMER_LAST_INTERRUPT_COUNT'
$timerLastWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_TIMER_LAST_WAKE_TICK'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_WAKE0_TICK'

if ($null -in @($interruptCount, $lastInterruptVector, $timerPendingWakeCount, $timerLastInterruptCount, $timerLastWakeTick, $wake0Tick)) {
    throw 'Missing expected interrupt-timeout manual-wake telemetry fields in probe output.'
}
if ($interruptCount -ne 0) { throw "Expected INTERRUPT_COUNT=0, got $interruptCount" }
if ($lastInterruptVector -ne 0) { throw "Expected LAST_INTERRUPT_VECTOR=0, got $lastInterruptVector" }
if ($timerPendingWakeCount -ne 1) { throw "Expected TIMER_PENDING_WAKE_COUNT=1, got $timerPendingWakeCount" }
if ($timerLastInterruptCount -ne 0) { throw "Expected TIMER_LAST_INTERRUPT_COUNT=0, got $timerLastInterruptCount" }
if ($timerLastWakeTick -ne $wake0Tick) { throw "Expected TIMER_LAST_WAKE_TICK to equal WAKE0_TICK. timer=$timerLastWakeTick wake=$wake0Tick" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_TELEMETRY_PRESERVE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_TELEMETRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1'
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "TIMER_LAST_WAKE_TICK=$timerLastWakeTick"
Write-Output "WAKE0_TICK=$wake0Tick"
