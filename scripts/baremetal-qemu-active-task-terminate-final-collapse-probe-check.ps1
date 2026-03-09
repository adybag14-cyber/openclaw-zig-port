param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-active-task-terminate-probe-check.ps1"
$schedulerNoSlot = 255
$taskTerminateOpcode = 28
$taskStateTerminated = 4

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
if ($probeText -match 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_FINAL_COLLAPSE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying active-task terminate probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'
$taskCount = Extract-IntValue -Text $probeText -Name 'TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'RUNNING_SLOT'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'DISPATCH_COUNT'
$lowState = Extract-IntValue -Text $probeText -Name 'LOW_STATE'
$highState = Extract-IntValue -Text $probeText -Name 'HIGH_STATE'
$lowRun = Extract-IntValue -Text $probeText -Name 'LOW_RUN'
$highRun = Extract-IntValue -Text $probeText -Name 'HIGH_RUN'

if ($null -in @($ack, $lastOpcode, $lastResult, $taskCount, $runningSlot, $dispatchCount, $lowState, $highState, $lowRun, $highRun)) {
    throw 'Missing expected final-collapse fields in active-task terminate probe output.'
}
if ($ack -ne 10) { throw "Expected ACK=10. got $ack" }
if ($lastOpcode -ne $taskTerminateOpcode) { throw "Expected LAST_OPCODE=28. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($taskCount -ne 0) { throw "Expected TASK_COUNT=0. got $taskCount" }
if ($runningSlot -ne $schedulerNoSlot) { throw "Expected RUNNING_SLOT=255. got $runningSlot" }
if ($dispatchCount -ne 3) { throw "Expected DISPATCH_COUNT=3. got $dispatchCount" }
if ($lowState -ne $taskStateTerminated -or $highState -ne $taskStateTerminated) {
    throw "Expected LOW_STATE/HIGH_STATE=4. got low=$lowState high=$highState"
}
if ($lowRun -ne 2 -or $highRun -ne 1) {
    throw "Expected LOW_RUN/HIGH_RUN=2/1. got low=$lowRun high=$highRun"
}

Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_FINAL_COLLAPSE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TASK_COUNT=$taskCount"
Write-Output "RUNNING_SLOT=$runningSlot"
Write-Output "DISPATCH_COUNT=$dispatchCount"
Write-Output "LOW_STATE=$lowState"
Write-Output "HIGH_STATE=$highState"
Write-Output "LOW_RUN=$lowRun"
Write-Output "HIGH_RUN=$highRun"
