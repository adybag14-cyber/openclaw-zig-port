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
    Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_DISPATCH_DRAIN_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-disable-reenable probe failed with exit code $probeExitCode"
}

$timerEntryCount = Extract-IntValue -Text $probeText -Name 'TIMER_ENTRY_COUNT'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'TIMER_DISPATCH_COUNT'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'WAKE_QUEUE_COUNT'

if ($null -in @($timerEntryCount, $timerDispatchCount, $wakeQueueCount)) {
    throw 'Missing expected timer-disable dispatch/drain fields in probe output.'
}
if ($timerEntryCount -ne 0) {
    throw "Expected timer table to drain after overdue wake dispatch. got $timerEntryCount"
}
if ($timerDispatchCount -ne 1) {
    throw "Expected exactly one timer dispatch after re-enable. got $timerDispatchCount"
}
if ($wakeQueueCount -ne 1) {
    throw "Expected exactly one queued wake after re-enable. got $wakeQueueCount"
}

Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_DISPATCH_DRAIN_PROBE=pass'
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
