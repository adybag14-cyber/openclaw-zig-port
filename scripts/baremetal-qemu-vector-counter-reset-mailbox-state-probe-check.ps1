param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-vector-counter-reset-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_VECTOR_COUNTER_RESET_MAILBOX_STATE_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-counter-reset probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_LAST_RESULT'
$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_MAILBOX_SEQ'
$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_TICKS'
if ($null -in @($ack, $lastOpcode, $lastResult, $mailboxOpcode, $mailboxSeq, $ticks)) {
    throw 'Missing final mailbox-state fields in vector-counter-reset output.'
}
if ($ack -ne 8 -or $lastOpcode -ne 15 -or $lastResult -ne 0 -or $mailboxOpcode -ne 15 -or $mailboxSeq -ne 8) {
    throw "Unexpected mailbox-state values after vector-counter reset: ack=$ack lastOpcode=$lastOpcode lastResult=$lastResult mailboxOpcode=$mailboxOpcode mailboxSeq=$mailboxSeq"
}
if ($ticks -lt 8) {
    throw "Expected TICKS>=8 after vector-counter reset, got $ticks"
}

Write-Output 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_MAILBOX_STATE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "TICKS=$ticks"
