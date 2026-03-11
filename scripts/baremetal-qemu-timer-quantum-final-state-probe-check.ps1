param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-quantum-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_FINAL_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-quantum probe failed with exit code $probeExitCode"
}
$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_LAST_RESULT'
$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_MAILBOX_SEQ'
$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TASK0_STATE'
$task0RunCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TASK0_RUN_COUNT'
$task0BudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TASK0_BUDGET_REMAINING'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER_ENTRY_COUNT'
$pendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_PENDING_WAKE_COUNT'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER_DISPATCH_COUNT'
$timer0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER0_STATE'
$timer0FireCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER0_FIRE_COUNT'
$timer0LastFireTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER0_LAST_FIRE_TICK'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE0_TICK'

if ($null -in @($ack, $lastOpcode, $lastResult, $mailboxOpcode, $mailboxSeq, $task0State, $task0RunCount, $task0BudgetRemaining, $timerEntryCount, $pendingWakeCount, $timerDispatchCount, $timer0State, $timer0FireCount, $timer0LastFireTick, $wake0Tick)) {
    throw 'Missing expected final-state fields in timer-quantum probe output.'
}
if ($ack -ne 7) { throw "Expected ACK=7. got $ack" }
if ($lastOpcode -ne 42) { throw "Expected LAST_OPCODE=42. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($mailboxOpcode -ne 42) { throw "Expected MAILBOX_OPCODE=42. got $mailboxOpcode" }
if ($mailboxSeq -ne 7) { throw "Expected MAILBOX_SEQ=7. got $mailboxSeq" }
if ($task0State -ne 1) { throw "Expected TASK0_STATE=1. got $task0State" }
if ($task0RunCount -ne 0) { throw "Expected TASK0_RUN_COUNT=0. got $task0RunCount" }
if ($task0BudgetRemaining -ne 9) { throw "Expected TASK0_BUDGET_REMAINING=9. got $task0BudgetRemaining" }
if ($timerEntryCount -ne 0) { throw "Expected TIMER_ENTRY_COUNT=0. got $timerEntryCount" }
if ($pendingWakeCount -ne 1) { throw "Expected PENDING_WAKE_COUNT=1. got $pendingWakeCount" }
if ($timerDispatchCount -ne 1) { throw "Expected TIMER_DISPATCH_COUNT=1. got $timerDispatchCount" }
if ($timer0State -ne 2) { throw "Expected TIMER0_STATE=2. got $timer0State" }
if ($timer0FireCount -ne 1) { throw "Expected TIMER0_FIRE_COUNT=1. got $timer0FireCount" }
if ($timer0LastFireTick -ne $wake0Tick) { throw "Expected TIMER0_LAST_FIRE_TICK to equal WAKE0_TICK. got $timer0LastFireTick vs $wake0Tick" }

Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_FINAL_STATE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "TASK0_STATE=$task0State"
Write-Output "TASK0_RUN_COUNT=$task0RunCount"
Write-Output "TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "PENDING_WAKE_COUNT=$pendingWakeCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "TIMER0_STATE=$timer0State"
Write-Output "TIMER0_FIRE_COUNT=$timer0FireCount"
Write-Output "TIMER0_LAST_FIRE_TICK=$timer0LastFireTick"
