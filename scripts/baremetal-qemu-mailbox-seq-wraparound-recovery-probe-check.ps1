param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-mailbox-seq-wraparound-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$probeOutput = & $probe @invoke 2>&1
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_MAILBOX_SEQ_WRAPAROUND_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MAILBOX_SEQ_WRAPAROUND_RECOVERY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying mailbox seq-wraparound probe failed with exit code $probeExitCode"
}

$expected = @{
    'PRE_WRAP_ACK' = 4294967295
    'PRE_WRAP_LAST_OPCODE' = 6
    'PRE_WRAP_LAST_RESULT' = 0
    'PRE_WRAP_TICK_BATCH_HINT' = 6
    'PRE_WRAP_MAILBOX_SEQ' = 4294967295
    'ACK' = 0
    'LAST_OPCODE' = 6
    'LAST_RESULT' = 0
    'TICK_BATCH_HINT' = 7
    'MAILBOX_SEQ' = 0
}

foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $probeText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}

Write-Output 'BAREMETAL_QEMU_MAILBOX_SEQ_WRAPAROUND_RECOVERY_PROBE=pass'
Write-Output 'PRE_WRAP_ACK=4294967295'
Write-Output 'PRE_WRAP_TICK_BATCH_HINT=6'
Write-Output 'ACK=0'
Write-Output 'TICK_BATCH_HINT=7'
Write-Output 'MAILBOX_SEQ=0'
