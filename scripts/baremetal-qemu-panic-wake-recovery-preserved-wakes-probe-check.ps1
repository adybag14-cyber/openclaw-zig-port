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
    Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PRESERVED_WAKES_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-wake recovery probe failed with exit code $probeExitCode"
}

$wake1TaskCount = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE1_TASK_COUNT'
$wake1Dispatch = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE1_DISPATCH_COUNT'
$wake1Queue = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE1_QUEUE_LEN'
$wake1Reason = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE1_REASON'
$wake1Vector = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE1_VECTOR'
$wake2TaskCount = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE2_TASK_COUNT'
$wake2Dispatch = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE2_DISPATCH_COUNT'
$wake2Queue = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE2_QUEUE_LEN'
$wake2TimerCount = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE2_TIMER_COUNT'
$wake2Pending = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE2_PENDING_WAKE_COUNT'
$wake2Reason = Extract-IntValue -Text $probeText -Name 'PANIC_WAKE2_REASON'

if ($null -in @($wake1TaskCount, $wake1Dispatch, $wake1Queue, $wake1Reason, $wake1Vector, $wake2TaskCount, $wake2Dispatch, $wake2Queue, $wake2TimerCount, $wake2Pending, $wake2Reason)) {
    throw 'Missing expected preserved-wake fields in panic-wake recovery probe output.'
}
if ($wake1TaskCount -ne 1) { throw "Expected PANIC_WAKE1_TASK_COUNT=1. got $wake1TaskCount" }
if ($wake1Dispatch -ne 0) { throw "Expected PANIC_WAKE1_DISPATCH_COUNT=0. got $wake1Dispatch" }
if ($wake1Queue -ne 1) { throw "Expected PANIC_WAKE1_QUEUE_LEN=1. got $wake1Queue" }
if ($wake1Reason -ne 2) { throw "Expected PANIC_WAKE1_REASON=2. got $wake1Reason" }
if ($wake1Vector -ne 200) { throw "Expected PANIC_WAKE1_VECTOR=200. got $wake1Vector" }
if ($wake2TaskCount -ne 2) { throw "Expected PANIC_WAKE2_TASK_COUNT=2. got $wake2TaskCount" }
if ($wake2Dispatch -ne 0) { throw "Expected PANIC_WAKE2_DISPATCH_COUNT=0. got $wake2Dispatch" }
if ($wake2Queue -ne 2) { throw "Expected PANIC_WAKE2_QUEUE_LEN=2. got $wake2Queue" }
if ($wake2TimerCount -ne 0) { throw "Expected PANIC_WAKE2_TIMER_COUNT=0. got $wake2TimerCount" }
if ($wake2Pending -ne 2) { throw "Expected PANIC_WAKE2_PENDING_WAKE_COUNT=2. got $wake2Pending" }
if ($wake2Reason -ne 1) { throw "Expected PANIC_WAKE2_REASON=1. got $wake2Reason" }

Write-Output 'BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PRESERVED_WAKES_PROBE=pass'
Write-Output "PANIC_WAKE1_TASK_COUNT=$wake1TaskCount"
Write-Output "PANIC_WAKE1_DISPATCH_COUNT=$wake1Dispatch"
Write-Output "PANIC_WAKE1_QUEUE_LEN=$wake1Queue"
Write-Output "PANIC_WAKE1_REASON=$wake1Reason"
Write-Output "PANIC_WAKE1_VECTOR=$wake1Vector"
Write-Output "PANIC_WAKE2_TASK_COUNT=$wake2TaskCount"
Write-Output "PANIC_WAKE2_DISPATCH_COUNT=$wake2Dispatch"
Write-Output "PANIC_WAKE2_QUEUE_LEN=$wake2Queue"
Write-Output "PANIC_WAKE2_TIMER_COUNT=$wake2TimerCount"
Write-Output "PANIC_WAKE2_PENDING_WAKE_COUNT=$wake2Pending"
Write-Output "PANIC_WAKE2_REASON=$wake2Reason"