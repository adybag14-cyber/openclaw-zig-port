param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-mask-clear-all-recovery-probe-check.ps1"

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_MASK_CLEAR_ALL_RECOVERY_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CLEAR_ALL_RECOVERY_MAILBOX_STATE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CLEAR_ALL_RECOVERY_MAILBOX_STATE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-clear-all-recovery-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-mask-clear-all-recovery probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_LAST_RESULT'
$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MAILBOX_SEQ'
$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TICKS'
if ($null -in @($ack, $lastOpcode, $lastResult, $mailboxOpcode, $mailboxSeq, $ticks)) {
    throw 'Missing mailbox-state fields in interrupt-mask-clear-all-recovery probe output.'
}
if ($ack -ne 17) { throw "Expected ACK=17, got $ack" }
if ($lastOpcode -ne 64) { throw "Expected LAST_OPCODE=64, got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0, got $lastResult" }
if ($mailboxOpcode -ne 64) { throw "Expected MAILBOX_OPCODE=64, got $mailboxOpcode" }
if ($mailboxSeq -ne 17) { throw "Expected MAILBOX_SEQ=17, got $mailboxSeq" }
if ($ticks -lt 7) { throw "Expected TICKS>=7, got $ticks" }
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CLEAR_ALL_RECOVERY_MAILBOX_STATE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CLEAR_ALL_RECOVERY_MAILBOX_STATE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-clear-all-recovery-probe-check.ps1'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "TICKS=$ticks"
