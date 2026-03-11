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
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_BLOCKED_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator/syscall failure probe failed with exit code $probeExitCode"
}

$expected = @{
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_BLOCKED_RESULT' = -17
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY_COUNT' = 1
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_FLAGS' = 1
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_INVOKE_COUNT' = 0
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_DISPATCH_COUNT' = 0
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_LAST_ID' = 0
}

foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $probeText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}

Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_BLOCKED_PROBE=pass'
Write-Output 'BLOCKED_RESULT=-17'
Write-Output 'SYSCALL_ENTRY_COUNT=1'
Write-Output 'SYSCALL_ENTRY0_FLAGS=1'
Write-Output 'SYSCALL_ENTRY0_INVOKE_COUNT=0'
Write-Output 'SYSCALL_DISPATCH_COUNT=0'
Write-Output 'SYSCALL_LAST_ID=0'
