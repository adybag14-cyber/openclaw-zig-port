param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-reset-recovery-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_TIMER_RESET_WAIT_KIND_ISOLATION_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-reset-recovery probe failed with exit code $probeExitCode"
}

$preWaitKind0 = Extract-IntValue -Text $probeText -Name 'PRE_WAIT_KIND0'
$postWaitKind0 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND0'
$preWaitKind1 = Extract-IntValue -Text $probeText -Name 'PRE_WAIT_KIND1'
$postWaitKind1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND1'
$preWaitTimeout1 = Extract-IntValue -Text $probeText -Name 'PRE_WAIT_TIMEOUT1'
$postWaitTimeout1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_TIMEOUT1'
$postTimerCount = Extract-IntValue -Text $probeText -Name 'POST_TIMER_COUNT'
$postWakeCount = Extract-IntValue -Text $probeText -Name 'POST_WAKE_COUNT'

if ($null -in @($preWaitKind0, $postWaitKind0, $preWaitKind1, $postWaitKind1, $preWaitTimeout1, $postWaitTimeout1, $postTimerCount, $postWakeCount)) {
    throw 'Missing expected timer-reset wait-kind isolation fields in probe output.'
}
if ($preWaitKind0 -ne 2 -or $postWaitKind0 -ne 1) {
    throw "Expected timer wait to collapse from timer(2) to manual(1). pre=$preWaitKind0 post=$postWaitKind0"
}
if ($preWaitKind1 -ne 3 -or $postWaitKind1 -ne 3) {
    throw "Expected interrupt-any wait to preserve its mode across timer reset. pre=$preWaitKind1 post=$postWaitKind1"
}
if ($preWaitTimeout1 -le 0) {
    throw "Expected interrupt-any timeout arm to be present before timer reset. got $preWaitTimeout1"
}
if ($postWaitTimeout1 -ne 0) {
    throw "Expected interrupt-any timeout arm to be cleared by timer reset. got $postWaitTimeout1"
}
if ($postTimerCount -ne 0) {
    throw "Expected timer table to be empty after timer reset. got $postTimerCount"
}
if ($postWakeCount -ne 0) {
    throw "Expected wake queue to remain empty immediately after timer reset. got $postWakeCount"
}

Write-Output 'BAREMETAL_QEMU_TIMER_RESET_WAIT_KIND_ISOLATION_PROBE=pass'
Write-Output "PRE_WAIT_KIND0=$preWaitKind0"
Write-Output "POST_WAIT_KIND0=$postWaitKind0"
Write-Output "PRE_WAIT_KIND1=$preWaitKind1"
Write-Output "POST_WAIT_KIND1=$postWaitKind1"
Write-Output "PRE_WAIT_TIMEOUT1=$preWaitTimeout1"
Write-Output "POST_WAIT_TIMEOUT1=$postWaitTimeout1"
Write-Output "POST_TIMER_COUNT=$postTimerCount"
Write-Output "POST_WAKE_COUNT=$postWakeCount"
