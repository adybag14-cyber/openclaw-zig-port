param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-task-terminate-mixed-state-probe-check.ps1"
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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_WAIT_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_WAIT_CLEAR_PROBE_SOURCE=baremetal-qemu-task-terminate-mixed-state-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying task-terminate mixed-state probe failed with exit code $probeExitCode"
}

$postWaitKind0 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND0'
$postWaitKind1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND1'
$postWaitTimeout0 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_TIMEOUT0'
$postWaitTimeout1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_TIMEOUT1'

if ($null -in @($postWaitKind0, $postWaitKind1, $postWaitTimeout0, $postWaitTimeout1)) {
    throw 'Missing expected wait-clear fields in task-terminate mixed-state probe output.'
}
if ($postWaitKind0 -ne 0) { throw "Expected POST_WAIT_KIND0=0. got $postWaitKind0" }
if ($postWaitKind1 -ne 0) { throw "Expected POST_WAIT_KIND1=0. got $postWaitKind1" }
if ($postWaitTimeout0 -ne 0) { throw "Expected POST_WAIT_TIMEOUT0=0. got $postWaitTimeout0" }
if ($postWaitTimeout1 -ne 0) { throw "Expected POST_WAIT_TIMEOUT1=0. got $postWaitTimeout1" }

Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_WAIT_CLEAR_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_WAIT_CLEAR_PROBE_SOURCE=baremetal-qemu-task-terminate-mixed-state-probe-check.ps1'
Write-Output "POST_WAIT_KIND0=$postWaitKind0"
Write-Output "POST_WAIT_KIND1=$postWaitKind1"
Write-Output "POST_WAIT_TIMEOUT0=$postWaitTimeout0"
Write-Output "POST_WAIT_TIMEOUT1=$postWaitTimeout1"
