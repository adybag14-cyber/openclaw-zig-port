param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_MAILBOX_STATE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_MAILBOX_STATE_PROBE_SOURCE=baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-terminate interrupt-timeout probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_LAST_RESULT'
$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_MAILBOX_SEQ'
$task0Budget = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_TASK0_BUDGET'
$task0BudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_PROBE_TASK0_BUDGET_REMAINING'

if ($null -in @($ack, $lastOpcode, $lastResult, $mailboxOpcode, $mailboxSeq, $task0Budget, $task0BudgetRemaining)) {
    throw 'Missing expected mailbox/final-state fields in task-terminate interrupt-timeout probe output.'
}
if ($ack -ne 8) { throw "Expected ACK=8. got $ack" }
if ($lastOpcode -ne 7) { throw "Expected LAST_OPCODE=7. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($mailboxOpcode -ne 7) { throw "Expected MAILBOX_OPCODE=7. got $mailboxOpcode" }
if ($mailboxSeq -ne 8) { throw "Expected MAILBOX_SEQ=8. got $mailboxSeq" }
if ($task0Budget -ne 5) { throw "Expected TASK0_BUDGET=5. got $task0Budget" }
if ($task0BudgetRemaining -ne 0) { throw "Expected TASK0_BUDGET_REMAINING=0. got $task0BudgetRemaining" }

Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_MAILBOX_STATE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_INTERRUPT_TIMEOUT_MAILBOX_STATE_PROBE_SOURCE=baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "TASK0_BUDGET=$task0Budget"
Write-Output "TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
