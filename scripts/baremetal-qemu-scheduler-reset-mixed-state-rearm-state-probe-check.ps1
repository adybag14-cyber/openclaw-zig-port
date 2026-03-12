param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-scheduler-reset-mixed-state-probe-check.ps1'
$taskWaitForOpcode = 53

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_REARM_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-reset mixed-state probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'
$freshTaskId = Extract-IntValue -Text $probeText -Name 'FRESH_TASK_ID'
$rearmTimerCount = Extract-IntValue -Text $probeText -Name 'REARM_TIMER_COUNT'
$rearmTimerId = Extract-IntValue -Text $probeText -Name 'REARM_TIMER_ID'
$rearmNextTimerId = Extract-IntValue -Text $probeText -Name 'REARM_NEXT_TIMER_ID'

if ($null -in @($ack, $lastOpcode, $lastResult, $freshTaskId, $rearmTimerCount, $rearmTimerId, $rearmNextTimerId)) {
    throw 'Missing expected scheduler-reset mixed-state rearm fields in probe output.'
}
if ($ack -ne 10) { throw "Expected ACK=10. got $ack" }
if ($lastOpcode -ne $taskWaitForOpcode) { throw "Expected LAST_OPCODE=53. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($freshTaskId -ne 1) { throw "Expected FRESH_TASK_ID=1. got $freshTaskId" }
if ($rearmTimerCount -ne 1) { throw "Expected REARM_TIMER_COUNT=1. got $rearmTimerCount" }
if ($rearmTimerId -ne 2) { throw "Expected REARM_TIMER_ID=2. got $rearmTimerId" }
if ($rearmNextTimerId -ne 3) { throw "Expected REARM_NEXT_TIMER_ID=3. got $rearmNextTimerId" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_REARM_STATE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "FRESH_TASK_ID=$freshTaskId"
Write-Output "REARM_TIMER_COUNT=$rearmTimerCount"
Write-Output "REARM_TIMER_ID=$rearmTimerId"
Write-Output "REARM_NEXT_TIMER_ID=$rearmNextTimerId"
