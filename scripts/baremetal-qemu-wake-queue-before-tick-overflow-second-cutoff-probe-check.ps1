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
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_SECOND_CUTOFF_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue before-tick overflow probe failed with exit code $probeExitCode"
}

$postSecondCount = Extract-IntValue -Text $probeText -Name 'POST_SECOND_COUNT'
$postSecondHead = Extract-IntValue -Text $probeText -Name 'POST_SECOND_HEAD'
$postSecondTail = Extract-IntValue -Text $probeText -Name 'POST_SECOND_TAIL'
$postSecondOverflow = Extract-IntValue -Text $probeText -Name 'POST_SECOND_OVERFLOW'
$postSecondSeq = Extract-IntValue -Text $probeText -Name 'POST_SECOND_SEQ'

if ($null -in @($postSecondCount, $postSecondHead, $postSecondTail, $postSecondOverflow, $postSecondSeq)) {
    throw 'Missing expected second-cutoff fields in wake-queue before-tick overflow probe output.'
}
if ($postSecondCount -ne 1) { throw "Expected POST_SECOND_COUNT=1. got $postSecondCount" }
if ($postSecondHead -ne 1) { throw "Expected POST_SECOND_HEAD=1. got $postSecondHead" }
if ($postSecondTail -ne 0) { throw "Expected POST_SECOND_TAIL=0. got $postSecondTail" }
if ($postSecondOverflow -ne 2) { throw "Expected POST_SECOND_OVERFLOW=2. got $postSecondOverflow" }
if ($postSecondSeq -ne 66) { throw "Expected POST_SECOND_SEQ=66. got $postSecondSeq" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_SECOND_CUTOFF_PROBE=pass'
Write-Output "POST_SECOND_COUNT=$postSecondCount"
Write-Output "POST_SECOND_HEAD=$postSecondHead"
Write-Output "POST_SECOND_TAIL=$postSecondTail"
Write-Output "POST_SECOND_OVERFLOW=$postSecondOverflow"
Write-Output "POST_SECOND_SEQ=$postSecondSeq"
