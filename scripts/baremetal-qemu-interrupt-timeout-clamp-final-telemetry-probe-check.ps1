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

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_FINAL_TELEMETRY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout clamp probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_LAST_RESULT'
$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_STATE'
$task0RunCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_RUN_COUNT'
$task0BudgetRemaining = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_BUDGET_REMAINING'

if ($null -in @($ack, $lastOpcode, $lastResult, $task0State, $task0RunCount, $task0BudgetRemaining)) {
    throw 'Missing expected final-telemetry fields in interrupt-timeout clamp probe output.'
}
if ($ack -ne 7) { throw "Expected ACK=7. got $ack" }
if ($lastOpcode -ne 58) { throw "Expected LAST_OPCODE=58. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($task0State -ne 1) { throw "Expected TASK0_STATE=1. got $task0State" }
if ($task0RunCount -ne 0) { throw "Expected TASK0_RUN_COUNT=0. got $task0RunCount" }
if ($task0BudgetRemaining -ne 4) { throw "Expected TASK0_BUDGET_REMAINING=4. got $task0BudgetRemaining" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_FINAL_TELEMETRY_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TASK0_STATE=$task0State"
Write-Output "TASK0_RUN_COUNT=$task0RunCount"
Write-Output "TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
