param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-wake-timer-clear-probe-check.ps1"
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-wake timer-clear probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'
$ticks = Extract-IntValue -Text $probeText -Name 'TICKS'
$taskId = Extract-IntValue -Text $probeText -Name 'TASK_ID'
$preTaskState = Extract-IntValue -Text $probeText -Name 'PRE_TASK_STATE'
$preTimerCount = Extract-IntValue -Text $probeText -Name 'PRE_TIMER_COUNT'
$preNextTimerId = Extract-IntValue -Text $probeText -Name 'PRE_NEXT_TIMER_ID'

if ($null -in @($ack, $lastOpcode, $lastResult, $ticks, $taskId, $preTaskState, $preTimerCount, $preNextTimerId)) {
    throw 'Missing expected scheduler-wake timer-clear baseline fields in probe output.'
}
if ($ack -ne 8) { throw "Expected ACK=8. got $ack" }
if ($lastOpcode -ne 53) { throw "Expected LAST_OPCODE=53. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($ticks -lt 8) { throw "Expected TICKS>=8. got $ticks" }
if ($taskId -le 0) { throw "Expected TASK_ID>0. got $taskId" }
if ($preTaskState -ne 6) { throw "Expected PRE_TASK_STATE=6. got $preTaskState" }
if ($preTimerCount -ne 1) { throw "Expected PRE_TIMER_COUNT=1. got $preTimerCount" }
if ($preNextTimerId -ne 2) { throw "Expected PRE_NEXT_TIMER_ID=2. got $preNextTimerId" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_BASELINE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TASK_ID=$taskId"
Write-Output "PRE_TASK_STATE=$preTaskState"
Write-Output "PRE_TIMER_COUNT=$preTimerCount"
Write-Output "PRE_NEXT_TIMER_ID=$preNextTimerId"