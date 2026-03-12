param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-clamp-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Extract-UIntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [UInt64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout clamp probe failed with exit code $probeExitCode"
}

$task0Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_ID'
$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_STATE'
$task0Priority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_PRIORITY'
$task0RunCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_RUN_COUNT'
$task0Budget = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_BUDGET'
$task0BudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_BUDGET_REMAINING'
$armTicks = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARM_TICKS'
$armedWaitTimeout = Extract-UIntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARMED_WAIT_TIMEOUT'

if ($null -in @($task0Id, $task0State, $task0Priority, $task0RunCount, $task0Budget, $task0BudgetRemaining, $armTicks, $armedWaitTimeout)) {
    throw 'Missing expected baseline fields in interrupt-timeout clamp probe output.'
}
if ($task0Id -ne 1) { throw "Expected TASK0_ID=1. got $task0Id" }
if ($task0State -ne 1) { throw "Expected TASK0_STATE=1. got $task0State" }
if ($task0Priority -ne 0) { throw "Expected TASK0_PRIORITY=0. got $task0Priority" }
if ($task0RunCount -ne 0) { throw "Expected TASK0_RUN_COUNT=0. got $task0RunCount" }
if ($task0Budget -ne 4) { throw "Expected TASK0_BUDGET=4. got $task0Budget" }
if ($task0BudgetRemaining -ne 4) { throw "Expected TASK0_BUDGET_REMAINING=4. got $task0BudgetRemaining" }
if ($armTicks -ne [UInt64]::MaxValue) { throw "Expected ARM_TICKS=$([UInt64]::MaxValue). got $armTicks" }
if ($armedWaitTimeout -ne [UInt64]::MaxValue) { throw "Expected ARMED_WAIT_TIMEOUT=$([UInt64]::MaxValue). got $armedWaitTimeout" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_BASELINE_PROBE=pass'
Write-Output "TASK0_ID=$task0Id"
Write-Output "TASK0_STATE=$task0State"
Write-Output "TASK0_PRIORITY=$task0Priority"
Write-Output "TASK0_RUN_COUNT=$task0RunCount"
Write-Output "TASK0_BUDGET=$task0Budget"
Write-Output "TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "ARM_TICKS=$armTicks"
Write-Output "ARMED_WAIT_TIMEOUT=$armedWaitTimeout"
