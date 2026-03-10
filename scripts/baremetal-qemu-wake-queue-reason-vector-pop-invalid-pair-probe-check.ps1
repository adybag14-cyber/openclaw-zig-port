param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-reason-vector-pop-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_INVALID_PAIR_PROBE=skipped'

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PROBE=skipped') {
    Write-Output $skipToken
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue reason-vector-pop probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_LAST_RESULT'
if ($null -in @($ack,$lastOpcode,$lastResult)) {
    throw 'Missing expected invalid-pair fields in wake-queue reason-vector-pop probe output.'
}
if ($lastOpcode -ne 62) { throw "Expected LAST_OPCODE=62. got $lastOpcode" }
if ($lastResult -ne -22) { throw "Expected LAST_RESULT=-22. got $lastResult" }
Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_INVALID_PAIR_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
