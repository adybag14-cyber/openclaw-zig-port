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
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PENDING_RESET_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-clear probe failed with exit code $probeExitCode"
}

$postClearPendingWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_PENDING_WAKE_COUNT'

if ($null -eq $postClearPendingWakeCount) {
    throw 'Missing expected post-clear pending-wake field in wake-queue-clear probe output.'
}
if ($postClearPendingWakeCount -ne 0) {
    throw "Expected POST_CLEAR_PENDING_WAKE_COUNT=0. got $postClearPendingWakeCount"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PENDING_RESET_PROBE=pass'
Write-Output "POST_CLEAR_PENDING_WAKE_COUNT=$postClearPendingWakeCount"
