param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-reset-recovery-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_POST_RESET_COLLAPSE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_POST_RESET_COLLAPSE_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-reset-recovery probe failed with exit code $probeExitCode"
}

$POST_TIMER_ENABLED = Extract-IntValue -Text $probeText -Name 'POST_TIMER_ENABLED'
$POST_TIMER_COUNT = Extract-IntValue -Text $probeText -Name 'POST_TIMER_COUNT'
$POST_WAKE_COUNT = Extract-IntValue -Text $probeText -Name 'POST_WAKE_COUNT'
$POST_NEXT_TIMER_ID = Extract-IntValue -Text $probeText -Name 'POST_NEXT_TIMER_ID'
$POST_DISPATCH_COUNT = Extract-IntValue -Text $probeText -Name 'POST_DISPATCH_COUNT'
$POST_LAST_WAKE_TICK = Extract-IntValue -Text $probeText -Name 'POST_LAST_WAKE_TICK'
$POST_QUANTUM = Extract-IntValue -Text $probeText -Name 'POST_QUANTUM'

if ($null -in @($POST_TIMER_ENABLED, $POST_TIMER_COUNT, $POST_WAKE_COUNT, $POST_NEXT_TIMER_ID, $POST_DISPATCH_COUNT, $POST_LAST_WAKE_TICK, $POST_QUANTUM)) {
    throw 'Missing expected timer-reset-recovery post-reset collapse fields in probe output.'
}
if ($POST_TIMER_ENABLED -ne 1) { throw "Expected POST_TIMER_ENABLED=1. got $POST_TIMER_ENABLED" }
if ($POST_TIMER_COUNT -ne 0) { throw "Expected POST_TIMER_COUNT=0. got $POST_TIMER_COUNT" }
if ($POST_WAKE_COUNT -ne 0) { throw "Expected POST_WAKE_COUNT=0. got $POST_WAKE_COUNT" }
if ($POST_NEXT_TIMER_ID -ne 1) { throw "Expected POST_NEXT_TIMER_ID=1. got $POST_NEXT_TIMER_ID" }
if ($POST_DISPATCH_COUNT -ne 0) { throw "Expected POST_DISPATCH_COUNT=0. got $POST_DISPATCH_COUNT" }
if ($POST_LAST_WAKE_TICK -ne 0) { throw "Expected POST_LAST_WAKE_TICK=0. got $POST_LAST_WAKE_TICK" }
if ($POST_QUANTUM -ne 1) { throw "Expected POST_QUANTUM=1. got $POST_QUANTUM" }

Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_POST_RESET_COLLAPSE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_POST_RESET_COLLAPSE_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
Write-Output "POST_TIMER_ENABLED=$POST_TIMER_ENABLED"
Write-Output "POST_TIMER_COUNT=$POST_TIMER_COUNT"
Write-Output "POST_WAKE_COUNT=$POST_WAKE_COUNT"
Write-Output "POST_NEXT_TIMER_ID=$POST_NEXT_TIMER_ID"
Write-Output "POST_DISPATCH_COUNT=$POST_DISPATCH_COUNT"
Write-Output "POST_LAST_WAKE_TICK=$POST_LAST_WAKE_TICK"
Write-Output "POST_QUANTUM=$POST_QUANTUM"
