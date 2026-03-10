param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-clear-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_REUSE_SHAPE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-clear probe failed with exit code $probeExitCode"
}

$postReuseCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_COUNT'
$postReuseHead = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_HEAD'
$postReuseTail = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_TAIL'
$postReuseOverflow = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_OVERFLOW'
$postReusePendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_PENDING_WAKE_COUNT'
$postReuseSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_SEQ'

if ($null -in @($postReuseCount, $postReuseHead, $postReuseTail, $postReuseOverflow, $postReusePendingWakeCount, $postReuseSeq)) {
    throw 'Missing expected post-reuse shape fields in wake-queue-clear probe output.'
}
if ($postReuseCount -ne 1 -or $postReuseHead -ne 1 -or $postReuseTail -ne 0 -or $postReuseOverflow -ne 0) {
    throw "Unexpected POST_REUSE queue summary: $postReuseCount/$postReuseHead/$postReuseTail/$postReuseOverflow"
}
if ($postReusePendingWakeCount -ne 1) {
    throw "Expected POST_REUSE_PENDING_WAKE_COUNT=1. got $postReusePendingWakeCount"
}
if ($postReuseSeq -ne 1) {
    throw "Expected POST_REUSE_SEQ=1. got $postReuseSeq"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_REUSE_SHAPE_PROBE=pass'
Write-Output "POST_REUSE_COUNT=$postReuseCount"
Write-Output "POST_REUSE_HEAD=$postReuseHead"
Write-Output "POST_REUSE_TAIL=$postReuseTail"
Write-Output "POST_REUSE_OVERFLOW=$postReuseOverflow"
Write-Output "POST_REUSE_PENDING_WAKE_COUNT=$postReusePendingWakeCount"
Write-Output "POST_REUSE_SEQ=$postReuseSeq"
