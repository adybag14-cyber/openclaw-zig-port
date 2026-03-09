param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-active-task-terminate-probe-check.ps1"

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
    Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_REPEAT_IDEMPOTENT_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying active-task terminate probe failed with exit code $probeExitCode"
}

$repeatResult = Extract-IntValue -Text $probeText -Name 'REPEAT_TERMINATE_RESULT'
if ($null -eq $repeatResult) {
    throw 'Missing REPEAT_TERMINATE_RESULT in active-task terminate probe output.'
}
if ($repeatResult -ne 0) { throw "Expected REPEAT_TERMINATE_RESULT=0. got $repeatResult" }

Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_REPEAT_IDEMPOTENT_PROBE=pass'
Write-Output "REPEAT_TERMINATE_RESULT=$repeatResult"
