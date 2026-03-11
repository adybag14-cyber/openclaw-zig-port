param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-manual-wait-interrupt-probe-check.ps1'

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_FINAL_TELEMETRY_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_FINAL_TELEMETRY_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait-interrupt probe failed with exit code $probeExitCode"
}

$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_INTERRUPT_COUNT'
$lastVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_INTERRUPT_VECTOR'
$manualWakeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TICK'
if ($null -in @($interruptCount, $lastVector, $manualWakeTick)) { throw 'Missing final-telemetry fields in manual-wait-interrupt probe output.' }
if ($interruptCount -ne 1) { throw "Expected INTERRUPT_COUNT=1, got $interruptCount" }
if ($lastVector -ne 44) { throw "Expected LAST_INTERRUPT_VECTOR=44, got $lastVector" }
if ($manualWakeTick -le 0) { throw "Expected MANUAL_WAKE_TICK > 0, got $manualWakeTick" }
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_FINAL_TELEMETRY_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_FINAL_TELEMETRY_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output 'INTERRUPT_COUNT=1'
Write-Output 'LAST_INTERRUPT_VECTOR=44'
Write-Output "MANUAL_WAKE_TICK=$manualWakeTick"
