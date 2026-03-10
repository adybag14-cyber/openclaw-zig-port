param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-saturation-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_SCHEDULER_SATURATION_TERMINATE_STATE_PROBE=skipped'

function Get-Int([string] $name) {
    $match = [regex]::Match($probeText, '(?m)^' + [regex]::Escape($name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { throw "Missing $name" }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_SATURATION_PROBE=skipped') {
    Write-Output $skipToken
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler saturation probe failed with exit code $probeExitCode"
}

$terminateLastResult = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_TERMINATE_LAST_RESULT"
$terminateTaskCount = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_TERMINATE_TASK_COUNT"
$terminatedState = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_TERMINATED_STATE"

if ($terminateLastResult -ne 0) { throw "Expected TERMINATE_LAST_RESULT=0, got $terminateLastResult" }
if ($terminateTaskCount -ne 15) { throw "Expected TERMINATE_TASK_COUNT=15, got $terminateTaskCount" }
if ($terminatedState -ne 4) { throw "Expected TERMINATED_STATE=4, got $terminatedState" }

Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_TERMINATE_STATE_PROBE=pass"
Write-Output "TERMINATE_LAST_RESULT=$terminateLastResult"
Write-Output "TERMINATE_TASK_COUNT=$terminateTaskCount"
Write-Output "TERMINATED_STATE=$terminatedState"
