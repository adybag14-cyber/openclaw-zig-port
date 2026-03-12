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
    Write-Output 'BAREMETAL_QEMU_MAILBOX_SEQ_WRAPAROUND_POST_WRAP_MAILBOX_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying mailbox seq-wraparound probe failed with exit code $probeExitCode"
}

$ticks = Extract-IntValue -Text $probeText -Name 'TICKS'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'MAILBOX_SEQ'
if ($null -eq $ticks) { throw 'Missing output value for TICKS' }
if ($null -eq $mailboxSeq) { throw 'Missing output value for MAILBOX_SEQ' }
if ($ticks -lt 2) { throw "Expected TICKS >= 2, got $ticks" }
if ($mailboxSeq -ne 0) { throw "Unexpected MAILBOX_SEQ: got $mailboxSeq expected 0" }

Write-Output 'BAREMETAL_QEMU_MAILBOX_SEQ_WRAPAROUND_POST_WRAP_MAILBOX_STATE_PROBE=pass'
Write-Output "TICKS=$ticks"
Write-Output 'MAILBOX_SEQ=0'
