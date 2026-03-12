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
    Write-Output 'BAREMETAL_QEMU_MAILBOX_SEQ_WRAPAROUND_PRE_WRAP_MAILBOX_SEQUENCE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying mailbox seq-wraparound probe failed with exit code $probeExitCode"
}

$preWrapMailboxSeq = Extract-IntValue -Text $probeText -Name 'PRE_WRAP_MAILBOX_SEQ'
if ($null -eq $preWrapMailboxSeq) { throw 'Missing output value for PRE_WRAP_MAILBOX_SEQ' }
if ($preWrapMailboxSeq -ne 4294967295) { throw "Unexpected PRE_WRAP_MAILBOX_SEQ: got $preWrapMailboxSeq expected 4294967295" }

Write-Output 'BAREMETAL_QEMU_MAILBOX_SEQ_WRAPAROUND_PRE_WRAP_MAILBOX_SEQUENCE_PROBE=pass'
Write-Output 'PRE_WRAP_MAILBOX_SEQ=4294967295'
