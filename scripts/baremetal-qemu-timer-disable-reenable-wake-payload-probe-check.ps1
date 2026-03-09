param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-disable-reenable-probe-check.ps1"
$wakeReasonTimer = 1

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_WAKE_PAYLOAD_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-disable-reenable probe failed with exit code $probeExitCode"
}

$wake0TimerId = Extract-IntValue -Text $probeText -Name 'WAKE0_TIMER_ID'
$wake0Reason = Extract-IntValue -Text $probeText -Name 'WAKE0_REASON'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'WAKE0_VECTOR'

if ($null -in @($wake0TimerId, $wake0Reason, $wake0Vector)) {
    throw 'Missing expected timer-disable wake payload fields in probe output.'
}
if ($wake0TimerId -ne 1) {
    throw "Expected overdue one-shot wake to preserve timer id 1. got $wake0TimerId"
}
if ($wake0Reason -ne $wakeReasonTimer) {
    throw "Expected overdue wake reason to remain timer(1). got $wake0Reason"
}
if ($wake0Vector -ne 0) {
    throw "Expected overdue timer wake vector to remain 0. got $wake0Vector"
}

Write-Output 'BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_WAKE_PAYLOAD_PROBE=pass'
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
