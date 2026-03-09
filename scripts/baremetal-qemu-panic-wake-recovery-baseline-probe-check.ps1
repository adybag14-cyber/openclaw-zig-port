param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-panic-wake-recovery-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-wake recovery probe failed with exit code $probeExitCode"
}

$taskCount = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_RUNNING_SLOT'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_DISPATCH_COUNT'
$task0State = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_TASK0_STATE'
$task1State = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_TASK1_STATE'
$timerCount = Extract-IntValue -Text $probeText -Name 'PRE_PANIC_TIMER_COUNT'

if ($null -in @($taskCount, $runningSlot, $dispatchCount, $task0State, $task1State, $timerCount)) {
    throw 'Missing expected baseline fields in panic-wake recovery probe output.'
}
if ($taskCount -ne 0) { throw "Expected PRE_PANIC_TASK_COUNT=0. got $taskCount" }
if ($runningSlot -ne 255) { throw "Expected PRE_PANIC_RUNNING_SLOT=255. got $runningSlot" }
if ($dispatchCount -ne 0) { throw "Expected PRE_PANIC_DISPATCH_COUNT=0. got $dispatchCount" }
if ($task0State -ne 6) { throw "Expected PRE_PANIC_TASK0_STATE=6. got $task0State" }
if ($task1State -ne 6) { throw "Expected PRE_PANIC_TASK1_STATE=6. got $task1State" }
if ($timerCount -ne 1) { throw "Expected PRE_PANIC_TIMER_COUNT=1. got $timerCount" }

Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_BASELINE_PROBE=pass'
Write-Output "PRE_PANIC_TASK_COUNT=$taskCount"
Write-Output "PRE_PANIC_RUNNING_SLOT=$runningSlot"
Write-Output "PRE_PANIC_DISPATCH_COUNT=$dispatchCount"
Write-Output "PRE_PANIC_TASK0_STATE=$task0State"
Write-Output "PRE_PANIC_TASK1_STATE=$task1State"
Write-Output "PRE_PANIC_TIMER_COUNT=$timerCount"