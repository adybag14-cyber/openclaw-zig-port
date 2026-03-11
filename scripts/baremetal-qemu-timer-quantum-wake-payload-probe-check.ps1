param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-quantum-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_WAKE_PAYLOAD_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-quantum probe failed with exit code $probeExitCode"
}
$expectedBoundaryTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_EXPECTED_BOUNDARY_TICK'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE_QUEUE_COUNT'
$wake0Seq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE0_SEQ'
$wake0TaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE0_TASK_ID'
$wake0TimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE0_TIMER_ID'
$wake0Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE0_REASON'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE0_VECTOR'
$wake0Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_WAKE0_TICK'
$timerLastWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER_LAST_WAKE_TICK'

if ($null -in @($expectedBoundaryTick, $wakeQueueCount, $wake0Seq, $wake0TaskId, $wake0TimerId, $wake0Reason, $wake0Vector, $wake0Tick, $timerLastWakeTick)) {
    throw 'Missing expected wake payload fields in timer-quantum probe output.'
}
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1. got $wakeQueueCount" }
if ($wake0Seq -ne 1) { throw "Expected WAKE0_SEQ=1. got $wake0Seq" }
if ($wake0TaskId -ne 1) { throw "Expected WAKE0_TASK_ID=1. got $wake0TaskId" }
if ($wake0TimerId -ne 1) { throw "Expected WAKE0_TIMER_ID=1. got $wake0TimerId" }
if ($wake0Reason -ne 1) { throw "Expected WAKE0_REASON=1. got $wake0Reason" }
if ($wake0Vector -ne 0) { throw "Expected WAKE0_VECTOR=0. got $wake0Vector" }
if ($wake0Tick -ne $expectedBoundaryTick) { throw "Expected WAKE0_TICK=$expectedBoundaryTick. got $wake0Tick" }
if ($timerLastWakeTick -ne $wake0Tick) { throw "Expected TIMER_LAST_WAKE_TICK to equal WAKE0_TICK. got $timerLastWakeTick vs $wake0Tick" }

Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_WAKE_PAYLOAD_PROBE=pass'
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_SEQ=$wake0Seq"
Write-Output "WAKE0_TASK_ID=$wake0TaskId"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "WAKE0_TICK=$wake0Tick"
