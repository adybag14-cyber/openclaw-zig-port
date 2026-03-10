param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-selective-overflow-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild -TimeoutSeconds 90 2>&1 } else { & $probe -TimeoutSeconds 90 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_REASON_VECTOR_SURVIVORS_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-selective-overflow probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'
$ticks = Extract-IntValue -Text $probeText -Name 'TICKS'
$firstSeq = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_FIRST_SEQ'
$firstVector = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_FIRST_VECTOR'
$lastSeq = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_LAST_SEQ'
$lastVector = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_LAST_VECTOR'

if ($null -in @($ack, $lastOpcode, $lastResult, $ticks, $firstSeq, $firstVector, $lastSeq, $lastVector)) {
    throw 'Missing expected final survivor fields in wake-queue-selective-overflow probe output.'
}
if ($ack -ne 139) { throw "Expected ACK=139. got $ack" }
if ($lastOpcode -ne 62) { throw "Expected LAST_OPCODE=62. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($ticks -lt 139) { throw "Expected TICKS >= 139. got $ticks" }
if ($firstSeq -ne 4 -or $firstVector -ne 31 -or $lastSeq -ne 66 -or $lastVector -ne 31) {
    throw 'Unexpected POST_REASON_VECTOR survivor ordering.'
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_REASON_VECTOR_SURVIVORS_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TICKS=$ticks"
Write-Output "POST_REASON_VECTOR_FIRST_SEQ=$firstSeq"
Write-Output "POST_REASON_VECTOR_FIRST_VECTOR=$firstVector"
Write-Output "POST_REASON_VECTOR_LAST_SEQ=$lastSeq"
Write-Output "POST_REASON_VECTOR_LAST_VECTOR=$lastVector"
