param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-disable-enable-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_ENABLE_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_REENABLE_TIMER_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout-disable-enable probe failed with exit code $probeExitCode"
}

$wake0Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_ENABLE_PROBE_WAKE0_REASON'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_ENABLE_PROBE_WAKE0_VECTOR'
$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_ENABLE_PROBE_INTERRUPT_COUNT'
$timerLastInterruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_ENABLE_PROBE_TIMER_LAST_INTERRUPT_COUNT'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_ENABLE_PROBE_TIMER_ENTRY_COUNT'
$wake0TimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_ENABLE_PROBE_WAKE0_TIMER_ID'

if ($null -in @($wake0Reason, $wake0Vector, $interruptCount, $timerLastInterruptCount, $timerEntryCount, $wake0TimerId)) {
    throw 'Missing expected interrupt-timeout disable/re-enable timer fields in probe output.'
}
if ($wake0Reason -ne 1) {
    throw "Expected timeout recovery wake to stay timer-based. got reason=$wake0Reason"
}
if ($wake0Vector -ne 0) {
    throw "Expected timeout recovery wake vector=0. got $wake0Vector"
}
if ($interruptCount -ne 0) {
    throw "Expected no real interrupt delivery in timer-only recovery path. got $interruptCount"
}
if ($timerLastInterruptCount -ne 0) {
    throw "Expected timer state interrupt counter to remain zero in timer-only recovery path. got $timerLastInterruptCount"
}
if ($timerEntryCount -ne 0) {
    throw "Expected no armed timer entries after overdue timeout recovery. got $timerEntryCount"
}
if ($wake0TimerId -ne 0) {
    throw "Expected timeout-backed interrupt wake to surface with timer_id=0. got $wake0TimerId"
}

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_REENABLE_TIMER_PROBE=pass'
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
