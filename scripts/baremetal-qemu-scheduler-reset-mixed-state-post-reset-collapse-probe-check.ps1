param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-scheduler-reset-mixed-state-probe-check.ps1'

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_POST_RESET_COLLAPSE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-reset mixed-state probe failed with exit code $probeExitCode"
}

$postTaskCount = Extract-IntValue -Text $probeText -Name 'POST_TASK_COUNT'
$postWakeCount = Extract-IntValue -Text $probeText -Name 'POST_WAKE_COUNT'
$postTimerCount = Extract-IntValue -Text $probeText -Name 'POST_TIMER_COUNT'
$postPendingWakeCount = Extract-IntValue -Text $probeText -Name 'POST_PENDING_WAKE_COUNT'
$postWaitKind0 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND0'
$postWaitKind1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND1'
$postWaitTimeout0 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_TIMEOUT0'
$postWaitTimeout1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_TIMEOUT1'

if ($null -in @($postTaskCount, $postWakeCount, $postTimerCount, $postPendingWakeCount, $postWaitKind0, $postWaitKind1, $postWaitTimeout0, $postWaitTimeout1)) {
    throw 'Missing expected scheduler-reset mixed-state post-reset fields in probe output.'
}
if ($postTaskCount -ne 0) { throw "Expected POST_TASK_COUNT=0. got $postTaskCount" }
if ($postWakeCount -ne 0) { throw "Expected POST_WAKE_COUNT=0. got $postWakeCount" }
if ($postTimerCount -ne 0) { throw "Expected POST_TIMER_COUNT=0. got $postTimerCount" }
if ($postPendingWakeCount -ne 0) { throw "Expected POST_PENDING_WAKE_COUNT=0. got $postPendingWakeCount" }
if ($postWaitKind0 -ne 0 -or $postWaitKind1 -ne 0) {
    throw "Expected POST_WAIT_KIND0/1=0/0. got $postWaitKind0/$postWaitKind1"
}
if ($postWaitTimeout0 -ne 0 -or $postWaitTimeout1 -ne 0) {
    throw "Expected POST_WAIT_TIMEOUT0/1=0/0. got $postWaitTimeout0/$postWaitTimeout1"
}

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_POST_RESET_COLLAPSE_PROBE=pass'
Write-Output "POST_TASK_COUNT=$postTaskCount"
Write-Output "POST_WAKE_COUNT=$postWakeCount"
Write-Output "POST_TIMER_COUNT=$postTimerCount"
Write-Output "POST_PENDING_WAKE_COUNT=$postPendingWakeCount"
Write-Output "POST_WAIT_KIND0=$postWaitKind0"
Write-Output "POST_WAIT_KIND1=$postWaitKind1"
Write-Output "POST_WAIT_TIMEOUT0=$postWaitTimeout0"
Write-Output "POST_WAIT_TIMEOUT1=$postWaitTimeout1"
