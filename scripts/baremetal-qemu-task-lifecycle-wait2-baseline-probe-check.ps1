param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-lifecycle-probe-check.ps1"
$taskStateWaiting = 6

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
if ($probeText -match 'BAREMETAL_QEMU_TASK_LIFECYCLE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying task-lifecycle probe failed with exit code $probeExitCode"
}

$wait2State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_STATE'
$wait2TaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_TASK_COUNT'

if ($null -in @($wait2State, $wait2TaskCount)) {
    throw 'Missing expected wait2 baseline fields in task-lifecycle probe output.'
}
if ($wait2State -ne $taskStateWaiting) { throw "Expected WAIT2_STATE=$taskStateWaiting. got $wait2State" }
if ($wait2TaskCount -ne 0) { throw "Expected WAIT2_TASK_COUNT=0. got $wait2TaskCount" }

Write-Output 'BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_BASELINE_PROBE=pass'
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_STATE=$wait2State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_TASK_COUNT=$wait2TaskCount"
