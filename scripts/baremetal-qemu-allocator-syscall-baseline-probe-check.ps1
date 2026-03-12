param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-allocator-syscall-probe-check.ps1"

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator-syscall probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_RESULT'
$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_TICKS'
$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_MAILBOX_SEQ'
if ($null -in @($ack,$lastOpcode,$lastResult,$ticks,$mailboxOpcode,$mailboxSeq)) { throw 'Missing baseline allocator-syscall fields.' }
if ($ack -ne 16) { throw "Expected ACK=16. got $ack" }
if ($lastOpcode -ne 37) { throw "Expected LAST_OPCODE=37. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($ticks -lt 16) { throw "Expected TICKS >= 16. got $ticks" }
if ($mailboxOpcode -ne 37) { throw "Expected MAILBOX_OPCODE=37. got $mailboxOpcode" }
if ($mailboxSeq -ne 16) { throw "Expected MAILBOX_SEQ=16. got $mailboxSeq" }
Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_BASELINE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TICKS=$ticks"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
