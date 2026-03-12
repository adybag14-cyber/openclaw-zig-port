param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds }
if ($GdbPort -gt 0) { $invoke.GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
$output | Write-Output
if ($outputText -match '(?m)^BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    throw "Mode/boot-phase history clear prerequisite probe failed with exit code $exitCode"
}
if ($outputText -notmatch '(?m)^BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PROBE=pass\r?$') {
    throw 'Missing broad mode/boot-phase history clear pass token'
}

Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_BASELINE_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
