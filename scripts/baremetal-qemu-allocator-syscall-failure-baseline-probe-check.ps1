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
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator/syscall failure probe failed with exit code $probeExitCode"
}

$expected = @{
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ACK' = 11
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_LAST_OPCODE' = 36
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_LAST_RESULT' = -38
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_MAILBOX_OPCODE' = 36
    'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_MAILBOX_SEQ' = 11
}

foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $probeText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}

$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_TICKS'
if ($null -eq $ticks) { throw 'Missing output value for TICKS' }
if ($ticks -lt 10) { throw "Unexpected TICKS: got $ticks expected at least 10" }

Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_BASELINE_PROBE=pass'
Write-Output 'ACK=11'
Write-Output 'LAST_OPCODE=36'
Write-Output 'LAST_RESULT=-38'
Write-Output 'MAILBOX_OPCODE=36'
Write-Output 'MAILBOX_SEQ=11'
Write-Output "TICKS=$ticks"
