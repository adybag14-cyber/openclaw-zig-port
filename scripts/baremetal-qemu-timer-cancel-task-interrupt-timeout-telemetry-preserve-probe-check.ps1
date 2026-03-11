param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1"
$interruptVector = 200

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
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-cancel-task interrupt-timeout probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_LAST_RESULT'
$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_MAILBOX_SEQ'
$timerEnabled = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_ENABLED'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TIMER_PENDING_WAKE_COUNT'
$timerNextTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_NEXT_TIMER_ID'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_DISPATCH_COUNT'
$timerLastInterruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_LAST_INTERRUPT_COUNT'
$timerLastWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_LAST_WAKE_TICK'
$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_INTERRUPT_COUNT'
$lastInterruptVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_LAST_INTERRUPT_VECTOR'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_TICK'

if ($null -in @($ack, $lastOpcode, $lastResult, $mailboxOpcode, $mailboxSeq, $timerEnabled, $timerPendingWakeCount, $timerNextTimerId, $timerDispatchCount, $timerLastInterruptCount, $timerLastWakeTick, $interruptCount, $lastInterruptVector, $wake0Tick)) {
    throw 'Missing expected timer-cancel-task interrupt-timeout telemetry fields in probe output.'
}
if ($ack -ne 8) { throw "Expected ACK=8, got $ack" }
if ($lastOpcode -ne 7) { throw "Expected LAST_OPCODE=7, got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0, got $lastResult" }
if ($mailboxOpcode -ne 7) { throw "Expected MAILBOX_OPCODE=7, got $mailboxOpcode" }
if ($mailboxSeq -ne 8) { throw "Expected MAILBOX_SEQ=8, got $mailboxSeq" }
if ($timerEnabled -ne 1) { throw "Expected TIMER_ENABLED=1, got $timerEnabled" }
if ($timerPendingWakeCount -ne 1) { throw "Expected TIMER_PENDING_WAKE_COUNT=1, got $timerPendingWakeCount" }
if ($timerNextTimerId -ne 1) { throw "Expected TIMER_NEXT_TIMER_ID=1, got $timerNextTimerId" }
if ($timerDispatchCount -ne 0) { throw "Expected TIMER_DISPATCH_COUNT=0, got $timerDispatchCount" }
if ($timerLastInterruptCount -ne 1) { throw "Expected TIMER_LAST_INTERRUPT_COUNT=1, got $timerLastInterruptCount" }
if ($timerLastWakeTick -ne $wake0Tick) { throw "Expected TIMER_LAST_WAKE_TICK to equal WAKE0_TICK. timer=$timerLastWakeTick wake=$wake0Tick" }
if ($interruptCount -ne 1) { throw "Expected INTERRUPT_COUNT=1, got $interruptCount" }
if ($lastInterruptVector -ne $interruptVector) { throw "Expected LAST_INTERRUPT_VECTOR=$interruptVector, got $lastInterruptVector" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "TIMER_ENABLED=$timerEnabled"
Write-Output "POST_IDLE_TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "TIMER_NEXT_TIMER_ID=$timerNextTimerId"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "TIMER_LAST_WAKE_TICK=$timerLastWakeTick"
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "WAKE0_TICK=$wake0Tick"
