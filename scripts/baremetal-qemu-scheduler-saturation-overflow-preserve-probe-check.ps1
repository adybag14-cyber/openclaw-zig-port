param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-saturation-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_SCHEDULER_SATURATION_OVERFLOW_PRESERVE_PROBE=skipped'

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

$overflowResult = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_OVERFLOW_RESULT"
$overflowTaskCount = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_OVERFLOW_TASK_COUNT"
$previousId = Get-Int "BAREMETAL_QEMU_SCHEDULER_SATURATION_REUSED_SLOT_PREVIOUS_ID"

if ($overflowResult -ne -28) { throw "Expected OVERFLOW_RESULT=-28, got $overflowResult" }
if ($overflowTaskCount -ne 16) { throw "Expected OVERFLOW_TASK_COUNT=16, got $overflowTaskCount" }
if ($previousId -le 0) { throw "Expected REUSED_SLOT_PREVIOUS_ID > 0, got $previousId" }

Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_OVERFLOW_PRESERVE_PROBE=pass"
Write-Output "OVERFLOW_RESULT=$overflowResult"
Write-Output "OVERFLOW_TASK_COUNT=$overflowTaskCount"
Write-Output "REUSED_SLOT_PREVIOUS_ID=$previousId"
