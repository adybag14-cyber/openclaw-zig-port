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
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_READY_STATE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_READY_STATE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait interrupt probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_RESULT'
$manualWakeTaskState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TASK_STATE'
$manualWakeTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TASK_COUNT'
if ($null -in @($ack, $lastOpcode, $lastResult, $manualWakeTaskState, $manualWakeTaskCount)) {
    throw 'Missing expected manual-wake ready-state fields in manual-wait interrupt probe output.'
}
if ($ack -ne 9) { throw "Expected ACK=9, got $ack" }
if ($lastOpcode -ne 45) { throw "Expected LAST_OPCODE=45, got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0, got $lastResult" }
if ($manualWakeTaskState -ne 1) { throw "Expected MANUAL_WAKE_TASK_STATE=1, got $manualWakeTaskState" }
if ($manualWakeTaskCount -ne 1) { throw "Expected MANUAL_WAKE_TASK_COUNT=1, got $manualWakeTaskCount" }

Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_READY_STATE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_READY_STATE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MANUAL_WAKE_TASK_STATE=$manualWakeTaskState"
Write-Output "MANUAL_WAKE_TASK_COUNT=$manualWakeTaskCount"
