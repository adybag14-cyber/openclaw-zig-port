param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-manual-wait-interrupt-probe-check.ps1"

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_PAYLOAD_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_PAYLOAD_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait interrupt probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TASK_ID'
$manualWakeQueueLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_QUEUE_LEN'
$manualWakeReason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_REASON'
$manualWakeTaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TASK_ID'
$manualWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TICK'
if ($null -in @($taskId, $manualWakeQueueLen, $manualWakeReason, $manualWakeTaskId, $manualWakeTick)) {
    throw 'Missing expected manual-wake payload fields in manual-wait interrupt probe output.'
}
if ($manualWakeQueueLen -ne 1) { throw "Expected MANUAL_WAKE_QUEUE_LEN=1, got $manualWakeQueueLen" }
if ($manualWakeReason -ne 3) { throw "Expected MANUAL_WAKE_REASON=3, got $manualWakeReason" }
if ($manualWakeTaskId -ne $taskId) { throw "Expected MANUAL_WAKE_TASK_ID=$taskId, got $manualWakeTaskId" }
if ($manualWakeTick -le 0) { throw "Expected MANUAL_WAKE_TICK > 0, got $manualWakeTick" }

Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_PAYLOAD_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_PAYLOAD_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output "MANUAL_WAKE_QUEUE_LEN=$manualWakeQueueLen"
Write-Output "MANUAL_WAKE_REASON=$manualWakeReason"
Write-Output "MANUAL_WAKE_TASK_ID=$manualWakeTaskId"
Write-Output "MANUAL_WAKE_TICK=$manualWakeTick"
