param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-timer-cancel-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_CANCELED_ENTRY_PRESERVE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-cancel probe failed with exit code $probeExitCode"
}

$preTaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_TIMER0_TASK_ID'
$preNextFire = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_TIMER0_NEXT_FIRE_TICK'
$timer0TaskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_TIMER0_TASK_ID'
$timer0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_TIMER0_STATE'
$timer0NextFire = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_TIMER0_NEXT_FIRE_TICK'
$timer0FireCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_TIMER0_FIRE_COUNT'
$timer0LastFireTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_TIMER0_LAST_FIRE_TICK'
$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_CANCEL_TASK0_STATE'

if ($null -in @($preTaskId, $preNextFire, $timer0TaskId, $timer0State, $timer0NextFire, $timer0FireCount, $timer0LastFireTick, $task0State)) {
    throw 'Missing canceled-entry timer-cancel fields.'
}
if ($timer0TaskId -ne $preTaskId) { throw "Expected TIMER0_TASK_ID=$preTaskId. got $timer0TaskId" }
if ($timer0State -ne 3) { throw "Expected TIMER0_STATE=3. got $timer0State" }
if ($timer0NextFire -ne $preNextFire) { throw "Expected TIMER0_NEXT_FIRE_TICK=$preNextFire. got $timer0NextFire" }
if ($timer0FireCount -ne 0) { throw "Expected TIMER0_FIRE_COUNT=0. got $timer0FireCount" }
if ($timer0LastFireTick -ne 0) { throw "Expected TIMER0_LAST_FIRE_TICK=0. got $timer0LastFireTick" }
if ($task0State -ne 6) { throw "Expected CANCEL_TASK0_STATE=6. got $task0State" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_CANCELED_ENTRY_PRESERVE_PROBE=pass'
Write-Output "TIMER0_TASK_ID=$timer0TaskId"
Write-Output "TIMER0_STATE=$timer0State"
Write-Output "TIMER0_NEXT_FIRE_TICK=$timer0NextFire"
Write-Output "TIMER0_FIRE_COUNT=$timer0FireCount"
Write-Output "TIMER0_LAST_FIRE_TICK=$timer0LastFireTick"
Write-Output "CANCEL_TASK0_STATE=$task0State"
