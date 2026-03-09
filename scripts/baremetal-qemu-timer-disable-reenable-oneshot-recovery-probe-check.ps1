param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-disable-reenable-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_ONESHOT_RECOVERY_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-disable-reenable probe failed with exit code $probeExitCode"
}

$wake0Reason = Extract-IntValue -Text $probeText -Name 'WAKE0_REASON'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'WAKE0_VECTOR'
$wake0TimerId = Extract-IntValue -Text $probeText -Name 'WAKE0_TIMER_ID'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'TIMER_DISPATCH_COUNT'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'WAKE_QUEUE_COUNT'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'TIMER_ENTRY_COUNT'

if ($null -in @($wake0Reason, $wake0Vector, $wake0TimerId, $timerDispatchCount, $wakeQueueCount, $timerEntryCount)) {
    throw 'Missing expected one-shot recovery fields in probe output.'
}
if ($wake0Reason -ne 1) {
    throw "Expected timer wake reason=1 after re-enable. got $wake0Reason"
}
if ($wake0Vector -ne 0) {
    throw "Expected timer wake vector=0 after re-enable. got $wake0Vector"
}
if ($wake0TimerId -ne 1) {
    throw "Expected one-shot wake to preserve timer id 1. got $wake0TimerId"
}
if ($timerDispatchCount -ne 1) {
    throw "Expected exactly one timer dispatch after re-enable. got $timerDispatchCount"
}
if ($wakeQueueCount -ne 1) {
    throw "Expected exactly one queued wake after re-enable. got $wakeQueueCount"
}
if ($timerEntryCount -ne 0) {
    throw "Expected timer table to drain after one-shot recovery. got $timerEntryCount"
}

Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_ONESHOT_RECOVERY_PROBE=pass'
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
