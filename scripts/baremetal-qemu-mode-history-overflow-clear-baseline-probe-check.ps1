param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Mode-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

foreach ($name in @(
    'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE',
    'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE'
)) {
    if ($outputText -notmatch ('(?m)^' + [regex]::Escape($name) + '=(.+)\r?$')) {
        throw "Missing expected output '$name'"
    }
}

Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
