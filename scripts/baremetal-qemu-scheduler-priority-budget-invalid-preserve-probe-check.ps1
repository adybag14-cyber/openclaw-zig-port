param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-priority-budget-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_INVALID_PRESERVE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-priority-budget probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LAST_RESULT'
$invalidPolicyResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_INVALID_POLICY_RESULT'
$policyAfterInvalid = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_POLICY_AFTER_INVALID'
$invalidTaskResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_INVALID_TASK_RESULT'
$lowPriorityAfterInvalid = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_PRIORITY_AFTER_INVALID'
$taskCountAfterInvalid = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_TASK_COUNT_AFTER_INVALID'

if ($null -in @($ack, $lastOpcode, $lastResult, $invalidPolicyResult, $policyAfterInvalid, $invalidTaskResult, $lowPriorityAfterInvalid, $taskCountAfterInvalid)) {
    throw 'Missing expected scheduler-priority-budget invalid-preserve fields in probe output.'
}
if ($ack -ne 11) { throw "Expected ACK=11. got $ack" }
if ($lastOpcode -ne 56 -or $lastResult -ne -2) { throw "Expected final invalid task result with opcode 56 / result -2. got opcode=$lastOpcode result=$lastResult" }
if ($invalidPolicyResult -ne -22) { throw "Expected INVALID_POLICY_RESULT=-22. got $invalidPolicyResult" }
if ($policyAfterInvalid -ne 1) { throw "Expected POLICY_AFTER_INVALID=1. got $policyAfterInvalid" }
if ($invalidTaskResult -ne -2) { throw "Expected INVALID_TASK_RESULT=-2. got $invalidTaskResult" }
if ($lowPriorityAfterInvalid -ne 15) { throw "Expected LOW_PRIORITY_AFTER_INVALID=15. got $lowPriorityAfterInvalid" }
if ($taskCountAfterInvalid -ne 2) { throw "Expected TASK_COUNT_AFTER_INVALID=2. got $taskCountAfterInvalid" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_INVALID_PRESERVE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "INVALID_POLICY_RESULT=$invalidPolicyResult"
Write-Output "POLICY_AFTER_INVALID=$policyAfterInvalid"
Write-Output "INVALID_TASK_RESULT=$invalidTaskResult"
Write-Output "LOW_PRIORITY_AFTER_INVALID=$lowPriorityAfterInvalid"
Write-Output "TASK_COUNT_AFTER_INVALID=$taskCountAfterInvalid"
