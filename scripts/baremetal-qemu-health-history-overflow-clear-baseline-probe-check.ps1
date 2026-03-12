param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Health-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

if ($outputText -notmatch '(?m)^BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE=pass\r?$') {
    throw 'Broad health-history overflow/clear probe did not report pass'
}
if ($outputText -notmatch '(?m)^BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-command-health-history-probe-check\.ps1,baremetal-qemu-bootdiag-history-clear-probe-check\.ps1\r?$') {
    throw 'Unexpected broad probe source metadata for health-history overflow/clear baseline wrapper'
}

Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
