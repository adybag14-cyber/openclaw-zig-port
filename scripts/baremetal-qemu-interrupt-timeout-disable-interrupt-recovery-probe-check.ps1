param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-timeout-disable-interrupt-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_RECOVERY_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-timeout-disable-interrupt probe failed with exit code $probeExitCode"
}

$wake0Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_REASON'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_VECTOR'
$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_INTERRUPT_COUNT'
$timerEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_ENTRY_COUNT'
$timerDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_DISPATCH_COUNT'
$lastInterruptVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_LAST_INTERRUPT_VECTOR'

if ($null -in @($wake0Reason, $wake0Vector, $interruptCount, $timerEntryCount, $timerDispatchCount, $lastInterruptVector)) {
    throw 'Missing expected interrupt-timeout direct-interrupt recovery fields in probe output.'
}
if ($wake0Reason -ne 2) {
    throw "Expected direct interrupt recovery wake reason=2. got $wake0Reason"
}
if ($wake0Vector -ne $lastInterruptVector) {
    throw "Expected wake vector to match delivered interrupt vector. wake=$wake0Vector last=$lastInterruptVector"
}
if ($interruptCount -ne 1) {
    throw "Expected exactly one delivered interrupt in direct interrupt recovery path. got $interruptCount"
}
if ($timerEntryCount -ne 0) {
    throw "Expected timeout arm to be cleared after direct interrupt recovery. got $timerEntryCount"
}
if ($timerDispatchCount -ne 0) {
    throw "Expected no timer dispatches in direct interrupt recovery path. got $timerDispatchCount"
}

Write-Output 'BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_RECOVERY_PROBE=pass'
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "LAST_INTERRUPT_VECTOR=$lastInterruptVector"
