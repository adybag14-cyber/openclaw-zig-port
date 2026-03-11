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
    Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-quantum probe failed with exit code $probeExitCode"
}
$armedTicks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_ARMED_TICKS'
$armedNextFireTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_ARMED_NEXT_FIRE_TICK'
$timerQuantum = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER_QUANTUM'
$schedTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_SCHED_TASK_COUNT'
$task0Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TASK0_ID'
$task0Priority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TASK0_PRIORITY'
$task0Budget = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TASK0_BUDGET'

if ($null -in @($armedTicks, $armedNextFireTick, $timerQuantum, $schedTaskCount, $task0Id, $task0Priority, $task0Budget)) {
    throw 'Missing expected baseline fields in timer-quantum probe output.'
}
if ($armedTicks -lt 1) { throw "Expected ARMED_TICKS>=1. got $armedTicks" }
if ($armedNextFireTick -ne $armedTicks) { throw "Expected ARMED_NEXT_FIRE_TICK to equal ARMED_TICKS. got $armedNextFireTick vs $armedTicks" }
if ($timerQuantum -ne 3) { throw "Expected TIMER_QUANTUM=3. got $timerQuantum" }
if ($schedTaskCount -ne 1) { throw "Expected SCHED_TASK_COUNT=1. got $schedTaskCount" }
if ($task0Id -ne 1) { throw "Expected TASK0_ID=1. got $task0Id" }
if ($task0Priority -ne 2) { throw "Expected TASK0_PRIORITY=2. got $task0Priority" }
if ($task0Budget -ne 9) { throw "Expected TASK0_BUDGET=9. got $task0Budget" }

Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_BASELINE_PROBE=pass'
Write-Output "ARMED_TICKS=$armedTicks"
Write-Output "ARMED_NEXT_FIRE_TICK=$armedNextFireTick"
Write-Output "TIMER_QUANTUM=$timerQuantum"
Write-Output "SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "TASK0_ID=$task0Id"
Write-Output "TASK0_PRIORITY=$task0Priority"
Write-Output "TASK0_BUDGET=$task0Budget"
