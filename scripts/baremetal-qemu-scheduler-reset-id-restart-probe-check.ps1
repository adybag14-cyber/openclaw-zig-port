param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-reset-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_RESET_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_ID_RESTART_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-reset probe failed with exit code $probeExitCode"
}

$postResetNextTaskId = Extract-IntValue -Text $probeText -Name 'POST_RESET_NEXT_TASK_ID'
$postCreateTaskId = Extract-IntValue -Text $probeText -Name 'POST_CREATE_TASK0_ID'
$nextTaskId = Extract-IntValue -Text $probeText -Name 'NEXT_TASK_ID'

if ($null -in @($postResetNextTaskId, $postCreateTaskId, $nextTaskId)) {
    throw 'Missing expected task-id restart fields in scheduler-reset probe output.'
}
if ($postResetNextTaskId -ne 1) { throw "Expected POST_RESET_NEXT_TASK_ID=1. got $postResetNextTaskId" }
if ($postCreateTaskId -ne 1) { throw "Expected POST_CREATE_TASK0_ID=1. got $postCreateTaskId" }
if ($nextTaskId -ne 2) { throw "Expected NEXT_TASK_ID=2. got $nextTaskId" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_ID_RESTART_PROBE=pass'
Write-Output "POST_RESET_NEXT_TASK_ID=$postResetNextTaskId"
Write-Output "POST_CREATE_TASK0_ID=$postCreateTaskId"
Write-Output "NEXT_TASK_ID=$nextTaskId"
