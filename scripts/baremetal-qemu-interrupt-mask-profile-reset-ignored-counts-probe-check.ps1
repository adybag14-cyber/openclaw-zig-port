param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 1348
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-mask-profile-probe-check.ps1"
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$probeOutput = & $probe @invoke 2>&1
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_RESET_IGNORED_COUNTS_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_RESET_IGNORED_COUNTS_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying interrupt-mask-profile probe failed with exit code $probeExitCode"
}

$ignoredCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_IGNORED_COUNT'
$ignored200 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_IGNORED_200'
$ignored201 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_IGNORED_201'
$lastMaskedVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_LAST_MASKED_VECTOR'
$profile = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_PROFILE'
$maskedCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_MASKED_COUNT'
$masked200 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_MASKED_200'
$masked201 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_RESET_MASKED_201'
if ($null -in @($ignoredCount, $ignored200, $ignored201, $lastMaskedVector, $profile, $maskedCount, $masked200, $masked201)) {
    throw 'Missing expected reset-ignored-counts fields in probe output.'
}
if ($ignoredCount -ne 0) { throw "Expected RESET_IGNORED_COUNT=0. got $ignoredCount" }
if ($ignored200 -ne 0) { throw "Expected RESET_IGNORED_200=0. got $ignored200" }
if ($ignored201 -ne 0) { throw "Expected RESET_IGNORED_201=0. got $ignored201" }
if ($lastMaskedVector -ne 0) { throw "Expected RESET_LAST_MASKED_VECTOR=0. got $lastMaskedVector" }
if ($profile -ne 255) { throw "Expected RESET_PROFILE=255. got $profile" }
if ($maskedCount -ne 223) { throw "Expected RESET_MASKED_COUNT=223. got $maskedCount" }
if ($masked200 -ne 0) { throw "Expected RESET_MASKED_200=0. got $masked200" }
if ($masked201 -ne 1) { throw "Expected RESET_MASKED_201=1. got $masked201" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_RESET_IGNORED_COUNTS_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_RESET_IGNORED_COUNTS_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
Write-Output "RESET_IGNORED_COUNT=$ignoredCount"
Write-Output "RESET_IGNORED_200=$ignored200"
Write-Output "RESET_IGNORED_201=$ignored201"
Write-Output "RESET_LAST_MASKED_VECTOR=$lastMaskedVector"
Write-Output "RESET_PROFILE=$profile"
Write-Output "RESET_MASKED_COUNT=$maskedCount"
Write-Output "RESET_MASKED_200=$masked200"
Write-Output "RESET_MASKED_201=$masked201"
