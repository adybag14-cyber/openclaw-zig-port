param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Extract-BoolValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(True|False)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [bool]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_MAILBOX_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler probe failed with exit code $probeExitCode"
}

$mailboxOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_MAILBOX_SEQ'
$timedOut = Extract-BoolValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TIMED_OUT'

if ($null -in @($mailboxOpcode, $mailboxSeq, $timedOut)) {
    throw 'Missing expected scheduler mailbox fields in probe output.'
}
if ($mailboxOpcode -ne 24) { throw "Expected MAILBOX_OPCODE=24. got $mailboxOpcode" }
if ($mailboxSeq -ne 5) { throw "Expected MAILBOX_SEQ=5. got $mailboxSeq" }
if ($timedOut) { throw 'Expected TIMED_OUT=False.' }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_MAILBOX_STATE_PROBE=pass'
Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "MAILBOX_SEQ=$mailboxSeq"
Write-Output "TIMED_OUT=$timedOut"
