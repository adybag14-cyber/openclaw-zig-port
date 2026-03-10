param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-reset-probe-check.ps1"
$schedulerNoSlot = 255

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
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_COLLAPSE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-reset probe failed with exit code $probeExitCode"
}

$enabled = Extract-IntValue -Text $probeText -Name 'POST_RESET_ENABLED'
$taskCount = Extract-IntValue -Text $probeText -Name 'POST_RESET_TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'POST_RESET_RUNNING_SLOT'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'POST_RESET_DISPATCH_COUNT'
$taskId = Extract-IntValue -Text $probeText -Name 'POST_RESET_TASK0_ID'

if ($null -in @($enabled, $taskCount, $runningSlot, $dispatchCount, $taskId)) {
    throw 'Missing expected collapse fields in scheduler-reset probe output.'
}
if ($enabled -ne 0) { throw "Expected POST_RESET_ENABLED=0. got $enabled" }
if ($taskCount -ne 0) { throw "Expected POST_RESET_TASK_COUNT=0. got $taskCount" }
if ($runningSlot -ne $schedulerNoSlot) { throw "Expected POST_RESET_RUNNING_SLOT=255. got $runningSlot" }
if ($dispatchCount -ne 0) { throw "Expected POST_RESET_DISPATCH_COUNT=0. got $dispatchCount" }
if ($taskId -ne 0) { throw "Expected POST_RESET_TASK0_ID=0. got $taskId" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_COLLAPSE_PROBE=pass'
Write-Output "POST_RESET_ENABLED=$enabled"
Write-Output "POST_RESET_TASK_COUNT=$taskCount"
Write-Output "POST_RESET_RUNNING_SLOT=$runningSlot"
Write-Output "POST_RESET_DISPATCH_COUNT=$dispatchCount"
Write-Output "POST_RESET_TASK0_ID=$taskId"
