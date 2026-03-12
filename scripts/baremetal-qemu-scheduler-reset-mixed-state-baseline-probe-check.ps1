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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-reset mixed-state probe failed with exit code $probeExitCode"
}

$preWakeCount = Extract-IntValue -Text $probeText -Name 'PRE_WAKE_COUNT'
$preTimerCount = Extract-IntValue -Text $probeText -Name 'PRE_TIMER_COUNT'
$prePendingWakeCount = Extract-IntValue -Text $probeText -Name 'PRE_PENDING_WAKE_COUNT'
$preNextTimerId = Extract-IntValue -Text $probeText -Name 'PRE_NEXT_TIMER_ID'
$preQuantum = Extract-IntValue -Text $probeText -Name 'PRE_QUANTUM'

if ($null -in @($preWakeCount, $preTimerCount, $prePendingWakeCount, $preNextTimerId, $preQuantum)) {
    throw 'Missing expected scheduler-reset mixed-state baseline fields in probe output.'
}
if ($preWakeCount -ne 1) { throw "Expected PRE_WAKE_COUNT=1. got $preWakeCount" }
if ($preTimerCount -ne 0) { throw "Expected PRE_TIMER_COUNT=0. got $preTimerCount" }
if ($prePendingWakeCount -ne 1) { throw "Expected PRE_PENDING_WAKE_COUNT=1. got $prePendingWakeCount" }
if ($preNextTimerId -ne 2) { throw "Expected PRE_NEXT_TIMER_ID=2. got $preNextTimerId" }
if ($preQuantum -ne 5) { throw "Expected PRE_QUANTUM=5. got $preQuantum" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_BASELINE_PROBE=pass'
Write-Output "PRE_WAKE_COUNT=$preWakeCount"
Write-Output "PRE_TIMER_COUNT=$preTimerCount"
Write-Output "PRE_PENDING_WAKE_COUNT=$prePendingWakeCount"
Write-Output "PRE_NEXT_TIMER_ID=$preNextTimerId"
Write-Output "PRE_QUANTUM=$preQuantum"
