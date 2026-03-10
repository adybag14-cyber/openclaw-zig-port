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
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_COLLAPSE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-clear probe failed with exit code $probeExitCode"
}

$postClearCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_COUNT'
$postClearHead = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_HEAD'
$postClearTail = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_TAIL'
$postClearOverflow = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_OVERFLOW'

if ($null -in @($postClearCount, $postClearHead, $postClearTail, $postClearOverflow)) {
    throw 'Missing expected post-clear collapse fields in wake-queue-clear probe output.'
}
if ($postClearCount -ne 0 -or $postClearHead -ne 0 -or $postClearTail -ne 0 -or $postClearOverflow -ne 0) {
    throw "Unexpected POST_CLEAR collapse: $postClearCount/$postClearHead/$postClearTail/$postClearOverflow"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_COLLAPSE_PROBE=pass'
Write-Output "POST_CLEAR_COUNT=$postClearCount"
Write-Output "POST_CLEAR_HEAD=$postClearHead"
Write-Output "POST_CLEAR_TAIL=$postClearTail"
Write-Output "POST_CLEAR_OVERFLOW=$postClearOverflow"
