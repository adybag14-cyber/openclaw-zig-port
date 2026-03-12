param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-reset-recovery-probe-check.ps1"
$taskStateWaiting = 6
$waitConditionManual = 1
$waitConditionInterruptAny = 3

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_WAIT_ISOLATION_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_WAIT_ISOLATION_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-reset-recovery probe failed with exit code $probeExitCode"
}

$POST_TASK0_STATE = Extract-IntValue -Text $probeText -Name 'POST_TASK0_STATE'
$POST_TASK1_STATE = Extract-IntValue -Text $probeText -Name 'POST_TASK1_STATE'
$POST_WAIT_KIND0 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND0'
$POST_WAIT_KIND1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_KIND1'
$POST_WAIT_TIMEOUT0 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_TIMEOUT0'
$POST_WAIT_TIMEOUT1 = Extract-IntValue -Text $probeText -Name 'POST_WAIT_TIMEOUT1'
$AFTER_IDLE_WAKE_COUNT = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_WAKE_COUNT'

if ($null -in @($POST_TASK0_STATE, $POST_TASK1_STATE, $POST_WAIT_KIND0, $POST_WAIT_KIND1, $POST_WAIT_TIMEOUT0, $POST_WAIT_TIMEOUT1, $AFTER_IDLE_WAKE_COUNT)) {
    throw 'Missing expected timer-reset-recovery wait-isolation fields in probe output.'
}
if ($POST_TASK0_STATE -ne $taskStateWaiting -or $POST_TASK1_STATE -ne $taskStateWaiting) { throw "Expected waiting task states after reset. got $POST_TASK0_STATE/$POST_TASK1_STATE" }
if ($POST_WAIT_KIND0 -ne $waitConditionManual -or $POST_WAIT_KIND1 -ne $waitConditionInterruptAny) { throw "Expected POST_WAIT_KIND0/1=1/3. got $POST_WAIT_KIND0/$POST_WAIT_KIND1" }
if ($POST_WAIT_TIMEOUT0 -ne 0) { throw "Expected POST_WAIT_TIMEOUT0=0. got $POST_WAIT_TIMEOUT0" }
if ($POST_WAIT_TIMEOUT1 -ne 0) { throw "Expected POST_WAIT_TIMEOUT1=0. got $POST_WAIT_TIMEOUT1" }
if ($AFTER_IDLE_WAKE_COUNT -ne 0) { throw "Expected AFTER_IDLE_WAKE_COUNT=0. got $AFTER_IDLE_WAKE_COUNT" }

Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_WAIT_ISOLATION_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_WAIT_ISOLATION_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
Write-Output "POST_TASK0_STATE=$POST_TASK0_STATE"
Write-Output "POST_TASK1_STATE=$POST_TASK1_STATE"
Write-Output "POST_WAIT_KIND0=$POST_WAIT_KIND0"
Write-Output "POST_WAIT_KIND1=$POST_WAIT_KIND1"
Write-Output "POST_WAIT_TIMEOUT0=$POST_WAIT_TIMEOUT0"
Write-Output "POST_WAIT_TIMEOUT1=$POST_WAIT_TIMEOUT1"
Write-Output "AFTER_IDLE_WAKE_COUNT=$AFTER_IDLE_WAKE_COUNT"
