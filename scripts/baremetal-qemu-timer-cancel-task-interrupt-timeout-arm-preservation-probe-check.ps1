param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_ARM_PRESERVATION_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_ARM_PRESERVATION_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-cancel-task interrupt-timeout probe failed with exit code $probeExitCode"
}

$armedTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_TICK'
$armedTask0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_TASK0_STATE'
$armedWaitKind0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAIT_KIND0'
$armedWaitVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAIT_VECTOR0'
$armedWaitTimeout0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAIT_TIMEOUT0'
$armedWakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAKE_QUEUE_COUNT'

if ($null -in @($armedTick, $armedTask0State, $armedWaitKind0, $armedWaitVector0, $armedWaitTimeout0, $armedWakeQueueCount)) {
    throw 'Missing expected timer-cancel-task interrupt-timeout arm-preservation fields in probe output.'
}
if ($armedTick -lt 0) { throw "Expected ARMED_TICK >= 0, got $armedTick" }
if ($armedTask0State -ne $taskStateWaiting) { throw "Expected ARMED_TASK0_STATE=6, got $armedTask0State" }
if ($armedWaitKind0 -ne $waitConditionInterruptAny) { throw "Expected ARMED_WAIT_KIND0=3, got $armedWaitKind0" }
if ($armedWaitVector0 -ne 0) { throw "Expected ARMED_WAIT_VECTOR0=0, got $armedWaitVector0" }
if ($armedWaitTimeout0 -le $armedTick) { throw "Expected ARMED_WAIT_TIMEOUT0 > ARMED_TICK. timeout=$armedWaitTimeout0 tick=$armedTick" }
if ($armedWakeQueueCount -ne 0) { throw "Expected ARMED_WAKE_QUEUE_COUNT=0, got $armedWakeQueueCount" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_ARM_PRESERVATION_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_ARM_PRESERVATION_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
Write-Output "ARMED_TICK=$armedTick"
Write-Output "ARMED_TASK0_STATE=$armedTask0State"
Write-Output "ARMED_WAIT_KIND0=$armedWaitKind0"
Write-Output "ARMED_WAIT_VECTOR0=$armedWaitVector0"
Write-Output "ARMED_WAIT_TIMEOUT0=$armedWaitTimeout0"
Write-Output "ARMED_WAKE_QUEUE_COUNT=$armedWakeQueueCount"
