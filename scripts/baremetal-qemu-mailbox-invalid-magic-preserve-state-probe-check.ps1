param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-mailbox-header-validation-probe-check.ps1"
$commandMagic = 0x4f43434d

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MAILBOX_INVALID_MAGIC_PRESERVE_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying mailbox header validation probe failed with exit code $probeExitCode"
}

$expected = @{
    'INVALID_MAGIC_ACK' = 1
    'INVALID_MAGIC_LAST_OPCODE' = 6
    'INVALID_MAGIC_LAST_RESULT' = -22
    'INVALID_MAGIC_TICK_BATCH_HINT' = 1
    'INVALID_MAGIC_MAILBOX_MAGIC' = 0
    'INVALID_MAGIC_MAILBOX_API_VERSION' = 2
    'INVALID_MAGIC_MAILBOX_SEQ' = 1
}

foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $probeText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}

Write-Output 'BAREMETAL_QEMU_MAILBOX_INVALID_MAGIC_PRESERVE_STATE_PROBE=pass'
Write-Output 'INVALID_MAGIC_ACK=1'
Write-Output 'INVALID_MAGIC_LAST_OPCODE=6'
Write-Output 'INVALID_MAGIC_LAST_RESULT=-22'
Write-Output 'INVALID_MAGIC_TICK_BATCH_HINT=1'
Write-Output 'INVALID_MAGIC_MAILBOX_MAGIC=0'
Write-Output 'INVALID_MAGIC_MAILBOX_API_VERSION=2'
Write-Output 'INVALID_MAGIC_MAILBOX_SEQ=1'

