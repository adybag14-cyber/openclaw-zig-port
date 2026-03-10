param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-saturation-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_SCHEDULER_SATURATION_BASELINE_PROBE=skipped'

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

$taskCapacity = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_TASK_CAPACITY"
$fullCount = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_FULL_COUNT"
$lastTaskId = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_LAST_TASK_ID"

if ($taskCapacity -ne 16) { throw "Expected TASK_CAPACITY=16, got $taskCapacity" }
if ($fullCount -ne 16) { throw "Expected FULL_COUNT=16, got $fullCount" }
if ($lastTaskId -ne 16) { throw "Expected LAST_TASK_ID=16, got $lastTaskId" }

Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_BASELINE_PROBE=pass"
Write-Output "TASK_CAPACITY=$taskCapacity"
Write-Output "FULL_COUNT=$fullCount"
Write-Output "LAST_TASK_ID=$lastTaskId"
