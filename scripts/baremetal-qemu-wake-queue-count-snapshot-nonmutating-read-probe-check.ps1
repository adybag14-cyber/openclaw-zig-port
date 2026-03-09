param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-count-snapshot-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_NONMUTATING_READ_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-count-snapshot probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_LAST_RESULT'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_MAILBOX_SEQ'
$preLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_LEN'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE_QUEUE_COUNT'
$timerPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_TIMER_PENDING_WAKE_COUNT'
$wake0Seq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_SEQ'
$wake0TaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_TASK_ID'
$wake0TimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_TIMER_ID'
$wake0Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_REASON'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_VECTOR'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_TICK'
$preOldestTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_OLDEST_TICK'

if ($null -in @($ack, $lastOpcode, $lastResult, $mailboxSeq, $preLen, $wakeQueueCount, $timerPendingWakeCount, $wake0Seq, $wake0TaskId, $wake0TimerId, $wake0Reason, $wake0Vector, $wake0Tick, $preOldestTick)) {
    throw 'Missing expected nonmutating-read fields in wake-queue-count-snapshot probe output.'
}
if ($ack -ne 19) { throw "Expected ACK=19. got $ack" }
if ($lastOpcode -ne 45) { throw "Expected LAST_OPCODE=45. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($mailboxSeq -ne 19) { throw "Expected MAILBOX_SEQ=19. got $mailboxSeq" }
if ($wakeQueueCount -ne $preLen) { throw "Expected queue length to stay unchanged after snapshot reads. pre=$preLen current=$wakeQueueCount" }
if ($timerPendingWakeCount -ne $wakeQueueCount) { throw "Expected pending wake count mirror to match queue count. pending=$timerPendingWakeCount count=$wakeQueueCount" }
if ($wake0Seq -ne 1 -or $wake0TaskId -ne 1 -or $wake0TimerId -le 0 -or $wake0Reason -ne 1 -or $wake0Vector -ne 0) {
    throw "Unexpected first wake identity after snapshot reads. seq=$wake0Seq task=$wake0TaskId timer=$wake0TimerId reason=$wake0Reason vector=$wake0Vector"
}
if ($wake0Tick -ne $preOldestTick) { throw "Expected first wake tick to remain oldest tick. wake0=$wake0Tick oldest=$preOldestTick" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_NONMUTATING_READ_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "WAKE0_SEQ=$wake0Seq"
Write-Output "WAKE0_TASK_ID=$wake0TaskId"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "WAKE0_TICK=$wake0Tick"
