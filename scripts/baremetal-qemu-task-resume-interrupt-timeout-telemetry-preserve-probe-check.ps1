param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1"
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-resume interrupt-timeout probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_LAST_RESULT'
$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_MAILBOX_SEQ'
$timerNextTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TIMER_NEXT_TIMER_ID'
$timerLastInterruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TIMER_LAST_INTERRUPT_COUNT'
$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_INTERRUPT_COUNT'
$lastInterruptVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_LAST_INTERRUPT_VECTOR'
$timerLastWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_TIMER_LAST_WAKE_TICK'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_PROBE_WAKE0_TICK'

if ($null -in @($ack, $lastOpcode, $lastResult, $mailboxOpcode, $mailboxSeq, $timerNextTimerId, $timerLastInterruptCount, $interruptCount, $lastInterruptVector, $timerLastWakeTick, $wake0Tick)) {
    throw 'Missing expected task-resume interrupt-timeout telemetry fields in probe output.'
}
if ($ack -ne 7) { throw "Expected ACK=7. got $ack" }
if ($lastOpcode -ne 51) { throw "Expected LAST_OPCODE=51. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($mailboxOpcode -ne 51) { throw "Expected MAILBOX_OPCODE=51. got $mailboxOpcode" }
if ($mailboxSeq -ne 7) { throw "Expected MAILBOX_SEQ=7. got $mailboxSeq" }
if ($timerNextTimerId -ne 1) { throw "Expected TIMER_NEXT_TIMER_ID=1. got $timerNextTimerId" }
if ($timerLastInterruptCount -ne 0) { throw "Expected TIMER_LAST_INTERRUPT_COUNT=0. got $timerLastInterruptCount" }
if ($interruptCount -ne 0) { throw "Expected INTERRUPT_COUNT=0. got $interruptCount" }
if ($lastInterruptVector -ne 0) { throw "Expected LAST_INTERRUPT_VECTOR=0. got $lastInterruptVector" }
if ($timerLastWakeTick -ne $wake0Tick) { throw "Expected TIMER_LAST_WAKE_TICK=$wake0Tick. got $timerLastWakeTick" }

Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_RESUME_INTERRUPT_TIMEOUT_TELEMETRY_PRESERVE_PROBE_SOURCE=baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "TIMER_NEXT_TIMER_ID=$timerNextTimerId"
Write-Output "TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "TIMER_LAST_WAKE_TICK=$timerLastWakeTick"
Write-Output "WAKE0_TICK=$wake0Tick"
