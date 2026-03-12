param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-clamp-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Extract-UIntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [UInt64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE_PAYLOAD_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout clamp probe failed with exit code $probeExitCode"
}

$task0Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_ID'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE_QUEUE_COUNT'
$wake0Seq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_SEQ'
$wake0TaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_TASK_ID'
$wake0TimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_TIMER_ID'
$wake0Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_REASON'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_VECTOR'
$wake0Tick = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_TICK'

if ($null -in @($task0Id, $wakeQueueCount, $wake0Seq, $wake0TaskId, $wake0TimerId, $wake0Reason, $wake0Vector, $wake0Tick)) {
    throw 'Missing expected wake-payload fields in interrupt-timeout clamp probe output.'
}
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1. got $wakeQueueCount" }
if ($wake0Seq -ne 1) { throw "Expected WAKE0_SEQ=1. got $wake0Seq" }
if ($wake0TaskId -ne $task0Id) { throw "Expected WAKE0_TASK_ID=$task0Id. got $wake0TaskId" }
if ($wake0TimerId -ne 0) { throw "Expected WAKE0_TIMER_ID=0. got $wake0TimerId" }
if ($wake0Reason -ne 1) { throw "Expected WAKE0_REASON=1. got $wake0Reason" }
if ($wake0Vector -ne 0) { throw "Expected WAKE0_VECTOR=0. got $wake0Vector" }
if ($wake0Tick -ne [UInt64]::MaxValue) { throw "Expected WAKE0_TICK=$([UInt64]::MaxValue). got $wake0Tick" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE_PAYLOAD_PROBE=pass'
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_SEQ=$wake0Seq"
Write-Output "WAKE0_TASK_ID=$wake0TaskId"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "WAKE0_TICK=$wake0Tick"
