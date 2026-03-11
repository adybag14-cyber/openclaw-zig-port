param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-allocator-syscall-failure-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$invoke = @{ TimeoutSeconds = $TimeoutSeconds }
if ($GdbPort -gt 0) { $invoke.GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$probeOutput = & $probe @invoke 2>&1
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_INVALID_ALIGN_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator/syscall failure probe failed with exit code $probeExitCode"
}

$expected = @{
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_INVALID_ALIGN_RESULT' = -22
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ALLOCATOR_FREE_PAGES_AFTER_FAILURE' = 256
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ALLOCATOR_ALLOCATION_COUNT_AFTER_FAILURE' = 0
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ALLOCATOR_BYTES_IN_USE_AFTER_FAILURE' = 0
}

foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $probeText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}

Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_INVALID_ALIGN_PROBE=pass'
Write-Output 'INVALID_ALIGN_RESULT=-22'
Write-Output 'ALLOCATOR_FREE_PAGES_AFTER_FAILURE=256'
Write-Output 'ALLOCATOR_ALLOCATION_COUNT_AFTER_FAILURE=0'
Write-Output 'ALLOCATOR_BYTES_IN_USE_AFTER_FAILURE=0'
