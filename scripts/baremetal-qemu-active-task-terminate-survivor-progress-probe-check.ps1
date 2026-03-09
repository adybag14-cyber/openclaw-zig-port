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
    Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_SURVIVOR_PROGRESS_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying active-task terminate probe failed with exit code $probeExitCode"
}

$lowRun = Extract-IntValue -Text $probeText -Name 'REPEAT_TERMINATE_LOW_RUN'
$lowBudget = Extract-IntValue -Text $probeText -Name 'REPEAT_TERMINATE_LOW_BUDGET_REMAINING'
if ($null -in @($lowRun, $lowBudget)) {
    throw 'Missing repeat survivor progress fields in active-task terminate probe output.'
}
if ($lowRun -ne 2) { throw "Expected REPEAT_TERMINATE_LOW_RUN=2. got $lowRun" }
if ($lowBudget -ne 4) { throw "Expected REPEAT_TERMINATE_LOW_BUDGET_REMAINING=4. got $lowBudget" }

Write-Output 'BAREMETAL_QEMU_ACTIVE_TASK_TERMINATE_SURVIVOR_PROGRESS_PROBE=pass'
Write-Output "REPEAT_TERMINATE_LOW_RUN=$lowRun"
Write-Output "REPEAT_TERMINATE_LOW_BUDGET_REMAINING=$lowBudget"
