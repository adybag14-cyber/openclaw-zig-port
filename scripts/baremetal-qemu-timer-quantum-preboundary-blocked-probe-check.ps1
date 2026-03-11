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
    Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_PREBOUNDARY_BLOCKED_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-quantum probe failed with exit code $probeExitCode"
}
$expectedBoundaryTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_EXPECTED_BOUNDARY_TICK'
$preBoundaryTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_PRE_BOUNDARY_TICK'
$preBoundaryWakeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_PRE_BOUNDARY_WAKE_COUNT'
$preBoundaryTaskState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_PRE_BOUNDARY_TASK_STATE'
$preBoundaryDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_QUANTUM_PROBE_PRE_BOUNDARY_DISPATCH_COUNT'

if ($null -in @($expectedBoundaryTick, $preBoundaryTick, $preBoundaryWakeCount, $preBoundaryTaskState, $preBoundaryDispatchCount)) {
    throw 'Missing expected pre-boundary fields in timer-quantum probe output.'
}
if ($preBoundaryTick -ne ($expectedBoundaryTick - 1)) { throw "Expected PRE_BOUNDARY_TICK=$(($expectedBoundaryTick - 1)). got $preBoundaryTick" }
if ($preBoundaryWakeCount -ne 0) { throw "Expected PRE_BOUNDARY_WAKE_COUNT=0. got $preBoundaryWakeCount" }
if ($preBoundaryTaskState -ne 6) { throw "Expected PRE_BOUNDARY_TASK_STATE=6. got $preBoundaryTaskState" }
if ($preBoundaryDispatchCount -ne 0) { throw "Expected PRE_BOUNDARY_DISPATCH_COUNT=0. got $preBoundaryDispatchCount" }

Write-Output 'BAREMETAL_QEMU_TIMER_QUANTUM_PREBOUNDARY_BLOCKED_PROBE=pass'
Write-Output "PRE_BOUNDARY_TICK=$preBoundaryTick"
Write-Output "PRE_BOUNDARY_WAKE_COUNT=$preBoundaryWakeCount"
Write-Output "PRE_BOUNDARY_TASK_STATE=$preBoundaryTaskState"
Write-Output "PRE_BOUNDARY_DISPATCH_COUNT=$preBoundaryDispatchCount"
