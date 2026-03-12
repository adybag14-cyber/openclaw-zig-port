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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler probe failed with exit code $probeExitCode"
}

$hitStart = Extract-BoolValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_HIT_START'
$hitAfter = Extract-BoolValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_HIT_AFTER_SCHEDULER'
$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_LAST_RESULT'
$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TICKS'

if ($null -in @($hitStart, $hitAfter, $ack, $lastOpcode, $lastResult, $ticks)) {
    throw 'Missing expected baseline scheduler fields in probe output.'
}
if (-not $hitStart) { throw 'Expected scheduler probe to hit _start.' }
if (-not $hitAfter) { throw 'Expected scheduler probe to reach post-scheduler stage.' }
if ($ack -ne 5) { throw "Expected ACK=5. got $ack" }
if ($lastOpcode -ne 24) { throw "Expected LAST_OPCODE=24. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($ticks -lt 1) { throw "Expected TICKS>=1. got $ticks" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_BASELINE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TICKS=$ticks"
