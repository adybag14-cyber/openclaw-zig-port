param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 1348
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CUSTOM_PROFILE_PRESERVE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CUSTOM_PROFILE_PRESERVE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Interrupt mask profile prerequisite probe failed with exit code $exitCode"
}

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$required = @(
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE'; Expected = 'pass'; Type = 'string' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_PROFILE'; Expected = 255; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_MASKED_COUNT'; Expected = 223; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_MASKED_201'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_IGNORED_COUNT'; Expected = 2; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_IGNORED_200'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_IGNORED_201'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_CUSTOM_LAST_MASKED_VECTOR'; Expected = 201; Type = 'int' }
)

foreach ($item in $required) {
    if ($item.Type -eq 'string') {
        $match = [regex]::Match($outputText, '(?m)^' + [regex]::Escape($item.Name) + '=(.+)$')
        if (-not $match.Success) { throw "Missing output value for $($item.Name)" }
        if ($match.Groups[1].Value.Trim() -ne $item.Expected) { throw "Unexpected $($item.Name): got $($match.Groups[1].Value.Trim()) expected $($item.Expected)" }
    } else {
        $value = Extract-IntValue -Text $outputText -Name $item.Name
        if ($null -eq $value) { throw "Missing output value for $($item.Name)" }
        if ($value -ne $item.Expected) { throw "Unexpected $($item.Name): got $value expected $($item.Expected)" }
    }
}

Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CUSTOM_PROFILE_PRESERVE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_CUSTOM_PROFILE_PRESERVE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
Write-Output 'CUSTOM_PROFILE=255'
Write-Output 'CUSTOM_MASKED_COUNT=223'
Write-Output 'CUSTOM_MASKED_201=1'
Write-Output 'CUSTOM_IGNORED_COUNT=2'
Write-Output 'CUSTOM_IGNORED_200=1'
Write-Output 'CUSTOM_IGNORED_201=1'
Write-Output 'CUSTOM_LAST_MASKED_VECTOR=201'
