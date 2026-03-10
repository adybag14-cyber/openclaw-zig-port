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
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_REASON_VECTOR_DRAIN_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-selective-overflow probe failed with exit code $probeExitCode"
}

$postCount = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_COUNT'
$postHead = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_HEAD'
$postTail = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_TAIL'
$postOverflow = Extract-IntValue -Text $probeText -Name 'POST_REASON_VECTOR_OVERFLOW'

if ($null -in @($postCount, $postHead, $postTail, $postOverflow)) {
    throw 'Missing expected post-reason-vector summary fields in wake-queue-selective-overflow probe output.'
}
if ($postCount -ne 32 -or $postHead -ne 32 -or $postTail -ne 0 -or $postOverflow -ne 2) {
    throw "Unexpected POST_REASON_VECTOR summary: $postCount/$postHead/$postTail/$postOverflow"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_REASON_VECTOR_DRAIN_PROBE=pass'
Write-Output "POST_REASON_VECTOR_COUNT=$postCount"
Write-Output "POST_REASON_VECTOR_HEAD=$postHead"
Write-Output "POST_REASON_VECTOR_TAIL=$postTail"
Write-Output "POST_REASON_VECTOR_OVERFLOW=$postOverflow"
