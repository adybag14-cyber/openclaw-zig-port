param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1"
$waitConditionInterruptAny = 3
$taskStateWaiting = 6

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
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_ARM_PRESERVATION_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_ARM_PRESERVATION_PROBE_SOURCE=baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout manual-wake probe failed with exit code $probeExitCode"
}

$beforeWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_BEFORE_WAKE_TICK'
$beforeWakeTask0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_BEFORE_WAKE_TASK0_STATE'
$beforeWakeWaitKind0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_BEFORE_WAKE_WAIT_KIND0'
$beforeWakeWaitVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_BEFORE_WAKE_WAIT_VECTOR0'
$beforeWakeWaitTimeout0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_BEFORE_WAKE_WAIT_TIMEOUT0'
$beforeWakeWakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_PROBE_BEFORE_WAKE_WAKE_QUEUE_COUNT'

if ($null -in @($beforeWakeTick, $beforeWakeTask0State, $beforeWakeWaitKind0, $beforeWakeWaitVector0, $beforeWakeWaitTimeout0, $beforeWakeWakeQueueCount)) {
    throw 'Missing expected interrupt-timeout manual-wake arm-preservation fields in probe output.'
}
if ($beforeWakeTick -lt 0) { throw "Expected BEFORE_WAKE_TICK >= 0, got $beforeWakeTick" }
if ($beforeWakeTask0State -ne $taskStateWaiting) { throw "Expected BEFORE_WAKE_TASK0_STATE=6, got $beforeWakeTask0State" }
if ($beforeWakeWaitKind0 -ne $waitConditionInterruptAny) { throw "Expected BEFORE_WAKE_WAIT_KIND0=3, got $beforeWakeWaitKind0" }
if ($beforeWakeWaitVector0 -ne 0) { throw "Expected BEFORE_WAKE_WAIT_VECTOR0=0, got $beforeWakeWaitVector0" }
if ($beforeWakeWaitTimeout0 -le $beforeWakeTick) { throw "Expected BEFORE_WAKE_WAIT_TIMEOUT0 > BEFORE_WAKE_TICK. timeout=$beforeWakeWaitTimeout0 tick=$beforeWakeTick" }
if ($beforeWakeWakeQueueCount -ne 0) { throw "Expected BEFORE_WAKE_WAKE_QUEUE_COUNT=0, got $beforeWakeWakeQueueCount" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_ARM_PRESERVATION_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_MANUAL_WAKE_ARM_PRESERVATION_PROBE_SOURCE=baremetal-qemu-interrupt-timeout-manual-wake-probe-check.ps1'
Write-Output "BEFORE_WAKE_TICK=$beforeWakeTick"
Write-Output "BEFORE_WAKE_TASK0_STATE=$beforeWakeTask0State"
Write-Output "BEFORE_WAKE_WAIT_KIND0=$beforeWakeWaitKind0"
Write-Output "BEFORE_WAKE_WAIT_VECTOR0=$beforeWakeWaitVector0"
Write-Output "BEFORE_WAKE_WAIT_TIMEOUT0=$beforeWakeWaitTimeout0"
Write-Output "BEFORE_WAKE_WAKE_QUEUE_COUNT=$beforeWakeWakeQueueCount"
