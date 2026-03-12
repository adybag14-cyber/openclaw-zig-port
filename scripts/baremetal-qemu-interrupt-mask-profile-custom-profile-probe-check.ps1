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
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_CUSTOM_PROFILE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_CUSTOM_PROFILE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying interrupt-mask-profile probe failed with exit code $probeExitCode"
}

$profile = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_PROFILE'
$maskedCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_MASKED_COUNT'
$masked201 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_MASKED_201'
$ignoredCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_IGNORED_COUNT'
$ignored200 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_IGNORED_200'
$ignored201 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_IGNORED_201'
$lastMaskedVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_LAST_MASKED_VECTOR'
if ($null -in @($profile, $maskedCount, $masked201, $ignoredCount, $ignored200, $ignored201, $lastMaskedVector)) {
    throw 'Missing expected custom-profile fields in probe output.'
}
if ($profile -ne 255) { throw "Expected CUSTOM_PROFILE=255. got $profile" }
if ($maskedCount -ne 223) { throw "Expected CUSTOM_MASKED_COUNT=223. got $maskedCount" }
if ($masked201 -ne 1) { throw "Expected CUSTOM_MASKED_201=1. got $masked201" }
if ($ignoredCount -ne 2) { throw "Expected CUSTOM_IGNORED_COUNT=2. got $ignoredCount" }
if ($ignored200 -ne 1) { throw "Expected CUSTOM_IGNORED_200=1. got $ignored200" }
if ($ignored201 -ne 1) { throw "Expected CUSTOM_IGNORED_201=1. got $ignored201" }
if ($lastMaskedVector -ne 201) { throw "Expected CUSTOM_LAST_MASKED_VECTOR=201. got $lastMaskedVector" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_CUSTOM_PROFILE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_CUSTOM_PROFILE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
Write-Output "CUSTOM_PROFILE=$profile"
Write-Output "CUSTOM_MASKED_COUNT=$maskedCount"
Write-Output "CUSTOM_MASKED_201=$masked201"
Write-Output "CUSTOM_IGNORED_COUNT=$ignoredCount"
Write-Output "CUSTOM_IGNORED_200=$ignored200"
Write-Output "CUSTOM_IGNORED_201=$ignored201"
Write-Output "CUSTOM_LAST_MASKED_VECTOR=$lastMaskedVector"
