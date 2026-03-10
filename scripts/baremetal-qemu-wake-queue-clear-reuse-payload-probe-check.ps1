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
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_REUSE_PAYLOAD_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-clear probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_TASK_ID'
$postReuseTaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_TASK_ID'
$postReuseReason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_REASON'
$postReuseTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_TICK'

if ($null -in @($taskId, $postReuseTaskId, $postReuseReason, $postReuseTick)) {
    throw 'Missing expected post-reuse payload fields in wake-queue-clear probe output.'
}
if ($postReuseTaskId -ne $taskId) {
    throw "Expected POST_REUSE_TASK_ID to match TASK_ID ($taskId). got $postReuseTaskId"
}
if ($postReuseReason -ne 3) {
    throw "Expected POST_REUSE_REASON=3. got $postReuseReason"
}
if ($postReuseTick -le 0) {
    throw "Expected POST_REUSE_TICK > 0. got $postReuseTick"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_REUSE_PAYLOAD_PROBE=pass'
Write-Output "TASK_ID=$taskId"
Write-Output "POST_REUSE_TASK_ID=$postReuseTaskId"
Write-Output "POST_REUSE_REASON=$postReuseReason"
Write-Output "POST_REUSE_TICK=$postReuseTick"
