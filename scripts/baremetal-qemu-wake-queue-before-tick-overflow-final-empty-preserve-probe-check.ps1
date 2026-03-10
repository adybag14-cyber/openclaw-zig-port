param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-before-tick-overflow-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_FINAL_EMPTY_PRESERVE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue before-tick overflow probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'
$finalCount = Extract-IntValue -Text $probeText -Name 'FINAL_COUNT'
$finalHead = Extract-IntValue -Text $probeText -Name 'FINAL_HEAD'
$finalTail = Extract-IntValue -Text $probeText -Name 'FINAL_TAIL'
$finalOverflow = Extract-IntValue -Text $probeText -Name 'FINAL_OVERFLOW'

if ($null -in @($ack, $lastOpcode, $lastResult, $finalCount, $finalHead, $finalTail, $finalOverflow)) {
    throw 'Missing expected final empty-preserve fields in wake-queue before-tick overflow probe output.'
}
if ($ack -ne 141) { throw "Expected ACK=141. got $ack" }
if ($lastOpcode -ne 61) { throw "Expected LAST_OPCODE=61. got $lastOpcode" }
if ($lastResult -ne -2) { throw "Expected LAST_RESULT=-2. got $lastResult" }
if ($finalCount -ne 0) { throw "Expected FINAL_COUNT=0. got $finalCount" }
if ($finalHead -ne 0) { throw "Expected FINAL_HEAD=0. got $finalHead" }
if ($finalTail -ne 0) { throw "Expected FINAL_TAIL=0. got $finalTail" }
if ($finalOverflow -ne 2) { throw "Expected FINAL_OVERFLOW=2. got $finalOverflow" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_FINAL_EMPTY_PRESERVE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "FINAL_COUNT=$finalCount"
Write-Output "FINAL_HEAD=$finalHead"
Write-Output "FINAL_TAIL=$finalTail"
Write-Output "FINAL_OVERFLOW=$finalOverflow"
