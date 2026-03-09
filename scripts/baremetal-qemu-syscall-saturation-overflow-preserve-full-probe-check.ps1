param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 45,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-syscall-saturation-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_SYSCALL_SATURATION_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_OVERFLOW_PRESERVE_FULL_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_OVERFLOW_PRESERVE_FULL_PROBE_SOURCE=baremetal-qemu-syscall-saturation-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Syscall saturation prerequisite probe failed with exit code $exitCode"
}

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$entryCapacity = Extract-IntValue -Text $outputText -Name 'ENTRY_CAPACITY'
$entryCount = Extract-IntValue -Text $outputText -Name 'ENTRY_COUNT'
$fullCount = Extract-IntValue -Text $outputText -Name 'FULL_COUNT'
$lastRegisteredId = Extract-IntValue -Text $outputText -Name 'LAST_REGISTERED_ID'
$overflowResult = Extract-IntValue -Text $outputText -Name 'OVERFLOW_RESULT'

if ($entryCapacity -ne 64) { throw "Expected ENTRY_CAPACITY=64. got $entryCapacity" }
if ($entryCount -ne 64) { throw "Expected final ENTRY_COUNT=64. got $entryCount" }
if ($fullCount -ne 64) { throw "Expected FULL_COUNT=64. got $fullCount" }
if ($lastRegisteredId -ne 64) { throw "Expected LAST_REGISTERED_ID=64 before overflow. got $lastRegisteredId" }
if ($overflowResult -ne -28) { throw "Expected OVERFLOW_RESULT=-28. got $overflowResult" }

Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_OVERFLOW_PRESERVE_FULL_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_OVERFLOW_PRESERVE_FULL_PROBE_SOURCE=baremetal-qemu-syscall-saturation-probe-check.ps1'
Write-Output "ENTRY_CAPACITY=$entryCapacity"
Write-Output "ENTRY_COUNT=$entryCount"
Write-Output "FULL_COUNT=$fullCount"
Write-Output "LAST_REGISTERED_ID=$lastRegisteredId"
Write-Output "OVERFLOW_RESULT=$overflowResult"
