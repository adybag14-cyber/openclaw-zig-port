param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-panic-recovery-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_PANIC_RECOVERY_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_MODE_RECOVERY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying panic-recovery probe failed with exit code $probeExitCode"
}

$recoverMode = Extract-IntValue -Text $probeText -Name 'RECOVER_MODE'
$recoverBootPhaseBefore = Extract-IntValue -Text $probeText -Name 'RECOVER_BOOT_PHASE_BEFORE'
$recoverDispatchCount = Extract-IntValue -Text $probeText -Name 'RECOVER_DISPATCH_COUNT'
$recoverRunCount = Extract-IntValue -Text $probeText -Name 'RECOVER_RUN_COUNT'

if ($null -in @($recoverMode, $recoverBootPhaseBefore, $recoverDispatchCount, $recoverRunCount)) {
    throw 'Missing expected recovery fields in panic-recovery probe output.'
}
if ($recoverMode -ne 1) { throw "Expected RECOVER_MODE=1. got $recoverMode" }
if ($recoverBootPhaseBefore -ne 255) { throw "Expected RECOVER_BOOT_PHASE_BEFORE=255. got $recoverBootPhaseBefore" }
if ($recoverDispatchCount -ne 2) { throw "Expected RECOVER_DISPATCH_COUNT=2. got $recoverDispatchCount" }
if ($recoverRunCount -ne 2) { throw "Expected RECOVER_RUN_COUNT=2. got $recoverRunCount" }

Write-Output 'BAREMETAL_QEMU_PANIC_RECOVERY_MODE_RECOVERY_PROBE=pass'
Write-Output "RECOVER_MODE=$recoverMode"
Write-Output "RECOVER_BOOT_PHASE_BEFORE=$recoverBootPhaseBefore"
Write-Output "RECOVER_DISPATCH_COUNT=$recoverDispatchCount"
Write-Output "RECOVER_RUN_COUNT=$recoverRunCount"
