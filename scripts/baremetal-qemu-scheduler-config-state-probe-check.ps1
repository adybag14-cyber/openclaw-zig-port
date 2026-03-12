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

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_CONFIG_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler probe failed with exit code $probeExitCode"
}

$enabled = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_ENABLED'
$taskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TASK_COUNT'
$runningSlot = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_RUNNING_SLOT'
$timeslice = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_TIMESLICE'
$policy = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_PROBE_POLICY'

if ($null -in @($enabled, $taskCount, $runningSlot, $timeslice, $policy)) {
    throw 'Missing expected scheduler config fields in probe output.'
}
if ($enabled -ne 1) { throw "Expected ENABLED=1. got $enabled" }
if ($taskCount -ne 1) { throw "Expected TASK_COUNT=1. got $taskCount" }
if ($runningSlot -ne 0) { throw "Expected RUNNING_SLOT=0. got $runningSlot" }
if ($timeslice -ne 3) { throw "Expected TIMESLICE=3. got $timeslice" }
if ($policy -ne 1) { throw "Expected POLICY=1. got $policy" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_CONFIG_STATE_PROBE=pass'
Write-Output "ENABLED=$enabled"
Write-Output "TASK_COUNT=$taskCount"
Write-Output "RUNNING_SLOT=$runningSlot"
Write-Output "TIMESLICE=$timeslice"
Write-Output "POLICY=$policy"
