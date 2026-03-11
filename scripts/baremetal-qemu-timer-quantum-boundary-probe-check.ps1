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
    Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_BOUNDARY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-quantum probe failed with exit code $probeExitCode"
}
$armedTicks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_ARMED_TICKS'
$armedNextFireTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_ARMED_NEXT_FIRE_TICK'
$timerQuantum = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_TIMER_QUANTUM'
$expectedBoundaryTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_EXPECTED_BOUNDARY_TICK'
$preBoundaryTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_PRE_BOUNDARY_TICK'
$postWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_POST_WAKE_TICK'

if ($null -in @($armedTicks, $armedNextFireTick, $timerQuantum, $expectedBoundaryTick, $preBoundaryTick, $postWakeTick)) {
    throw 'Missing expected boundary fields in timer-quantum probe output.'
}
$recomputedBoundary = (([int64]([math]::Floor($armedTicks / $timerQuantum))) + 1) * $timerQuantum
if ($expectedBoundaryTick -ne $recomputedBoundary) { throw "Expected recomputed boundary $recomputedBoundary. got $expectedBoundaryTick" }
if ($expectedBoundaryTick -le $armedNextFireTick) { throw "Expected EXPECTED_BOUNDARY_TICK > ARMED_NEXT_FIRE_TICK. got $expectedBoundaryTick <= $armedNextFireTick" }
if ($preBoundaryTick -ne ($expectedBoundaryTick - 1)) { throw "Expected PRE_BOUNDARY_TICK=$(($expectedBoundaryTick - 1)). got $preBoundaryTick" }
if ($postWakeTick -ne ($expectedBoundaryTick + 1)) { throw "Expected POST_WAKE_TICK=$(($expectedBoundaryTick + 1)). got $postWakeTick" }

Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_BOUNDARY_PROBE=pass'
Write-Output "ARMED_TICKS=$armedTicks"
Write-Output "ARMED_NEXT_FIRE_TICK=$armedNextFireTick"
Write-Output "EXPECTED_BOUNDARY_TICK=$expectedBoundaryTick"
Write-Output "PRE_BOUNDARY_TICK=$preBoundaryTick"
Write-Output "POST_WAKE_TICK=$postWakeTick"
