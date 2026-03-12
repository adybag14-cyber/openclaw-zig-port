param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-reset-recovery-probe-check.ps1"
$taskStateWaiting = 6
$waitConditionTimer = 2
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
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_BASELINE_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-reset-recovery probe failed with exit code $probeExitCode"
}

$TASK0_ID = Extract-IntValue -Text $probeText -Name 'TASK0_ID'
$TASK1_ID = Extract-IntValue -Text $probeText -Name 'TASK1_ID'
$PRE_TIMER_ENABLED = Extract-IntValue -Text $probeText -Name 'PRE_TIMER_ENABLED'
$PRE_TIMER_COUNT = Extract-IntValue -Text $probeText -Name 'PRE_TIMER_COUNT'
$PRE_WAKE_COUNT = Extract-IntValue -Text $probeText -Name 'PRE_WAKE_COUNT'
$PRE_NEXT_TIMER_ID = Extract-IntValue -Text $probeText -Name 'PRE_NEXT_TIMER_ID'
$PRE_QUANTUM = Extract-IntValue -Text $probeText -Name 'PRE_QUANTUM'
$PRE_TASK0_STATE = Extract-IntValue -Text $probeText -Name 'PRE_TASK0_STATE'
$PRE_TASK1_STATE = Extract-IntValue -Text $probeText -Name 'PRE_TASK1_STATE'
$PRE_WAIT_KIND0 = Extract-IntValue -Text $probeText -Name 'PRE_WAIT_KIND0'
$PRE_WAIT_KIND1 = Extract-IntValue -Text $probeText -Name 'PRE_WAIT_KIND1'
$PRE_WAIT_TIMEOUT0 = Extract-IntValue -Text $probeText -Name 'PRE_WAIT_TIMEOUT0'
$PRE_WAIT_TIMEOUT1 = Extract-IntValue -Text $probeText -Name 'PRE_WAIT_TIMEOUT1'

if ($null -in @($TASK0_ID, $TASK1_ID, $PRE_TIMER_ENABLED, $PRE_TIMER_COUNT, $PRE_WAKE_COUNT, $PRE_NEXT_TIMER_ID, $PRE_QUANTUM, $PRE_TASK0_STATE, $PRE_TASK1_STATE, $PRE_WAIT_KIND0, $PRE_WAIT_KIND1, $PRE_WAIT_TIMEOUT0, $PRE_WAIT_TIMEOUT1)) {
    throw 'Missing expected timer-reset-recovery baseline fields in probe output.'
}
if ($TASK0_ID -le 0 -or $TASK1_ID -le 0) { throw "Expected positive task ids. got TASK0_ID=$TASK0_ID TASK1_ID=$TASK1_ID" }
if ($PRE_TIMER_ENABLED -ne 0) { throw "Expected PRE_TIMER_ENABLED=0. got $PRE_TIMER_ENABLED" }
if ($PRE_TIMER_COUNT -ne 1) { throw "Expected PRE_TIMER_COUNT=1. got $PRE_TIMER_COUNT" }
if ($PRE_WAKE_COUNT -ne 0) { throw "Expected PRE_WAKE_COUNT=0. got $PRE_WAKE_COUNT" }
if ($PRE_NEXT_TIMER_ID -ne 2) { throw "Expected PRE_NEXT_TIMER_ID=2. got $PRE_NEXT_TIMER_ID" }
if ($PRE_QUANTUM -ne 5) { throw "Expected PRE_QUANTUM=5. got $PRE_QUANTUM" }
if ($PRE_TASK0_STATE -ne $taskStateWaiting -or $PRE_TASK1_STATE -ne $taskStateWaiting) { throw "Expected waiting task states before reset. got $PRE_TASK0_STATE/$PRE_TASK1_STATE" }
if ($PRE_WAIT_KIND0 -ne $waitConditionTimer -or $PRE_WAIT_KIND1 -ne $waitConditionInterruptAny) { throw "Expected PRE_WAIT_KIND0/1=2/3. got $PRE_WAIT_KIND0/$PRE_WAIT_KIND1" }
if ($PRE_WAIT_TIMEOUT0 -ne 0) { throw "Expected PRE_WAIT_TIMEOUT0=0. got $PRE_WAIT_TIMEOUT0" }
if ($PRE_WAIT_TIMEOUT1 -le 0) { throw "Expected PRE_WAIT_TIMEOUT1>0. got $PRE_WAIT_TIMEOUT1" }

Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_TIMER_RESET_RECOVERY_BASELINE_PROBE_SOURCE=baremetal-qemu-timer-reset-recovery-probe-check.ps1'
Write-Output "TASK0_ID=$TASK0_ID"
Write-Output "TASK1_ID=$TASK1_ID"
Write-Output "PRE_TIMER_ENABLED=$PRE_TIMER_ENABLED"
Write-Output "PRE_TIMER_COUNT=$PRE_TIMER_COUNT"
Write-Output "PRE_WAKE_COUNT=$PRE_WAKE_COUNT"
Write-Output "PRE_NEXT_TIMER_ID=$PRE_NEXT_TIMER_ID"
Write-Output "PRE_QUANTUM=$PRE_QUANTUM"
Write-Output "PRE_TASK0_STATE=$PRE_TASK0_STATE"
Write-Output "PRE_TASK1_STATE=$PRE_TASK1_STATE"
Write-Output "PRE_WAIT_KIND0=$PRE_WAIT_KIND0"
Write-Output "PRE_WAIT_KIND1=$PRE_WAIT_KIND1"
Write-Output "PRE_WAIT_TIMEOUT0=$PRE_WAIT_TIMEOUT0"
Write-Output "PRE_WAIT_TIMEOUT1=$PRE_WAIT_TIMEOUT1"
