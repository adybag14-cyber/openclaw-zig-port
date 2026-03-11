param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-vector-history-overflow-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_MAILBOX_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-history-overflow probe failed with exit code $probeExitCode"
}

$interruptHistoryLen = Extract-IntValue -Text $probeText -Name 'INTERRUPT_HISTORY_LEN_PHASE_B'
$interruptHistoryOverflow = Extract-IntValue -Text $probeText -Name 'INTERRUPT_HISTORY_OVERFLOW_PHASE_B'
$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'

if ($null -in @($interruptHistoryLen, $interruptHistoryOverflow, $ack, $lastOpcode, $lastResult)) {
    throw 'Missing final mailbox-state vector-history-overflow fields.'
}
if ($interruptHistoryLen -ne 19) { throw "Expected INTERRUPT_HISTORY_LEN_PHASE_B=19. got $interruptHistoryLen" }
if ($interruptHistoryOverflow -ne 0) { throw "Expected INTERRUPT_HISTORY_OVERFLOW_PHASE_B=0. got $interruptHistoryOverflow" }
if ($ack -ne 62) { throw "Expected ACK=62. got $ack" }
if ($lastOpcode -ne 12) { throw "Expected LAST_OPCODE=12. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }

Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_MAILBOX_STATE_PROBE=pass'
Write-Output "INTERRUPT_HISTORY_LEN_PHASE_B=$interruptHistoryLen"
Write-Output "INTERRUPT_HISTORY_OVERFLOW_PHASE_B=$interruptHistoryOverflow"
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
