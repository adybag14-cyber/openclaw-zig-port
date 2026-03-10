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
    Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_CANCEL_COLLAPSE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying timer-cancel probe failed with exit code $probeExitCode"
}

$cancelTicks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_CANCEL_TICKS'
$cancelCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_CANCEL_ENTRY_COUNT'
$cancelTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_CANCEL_TIMER0_ID'
$cancelTimerState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_CANCEL_TIMER0_STATE'
$preTimerId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_TIMER_CANCEL_PROBE_PRE_CANCEL_TIMER0_ID'

if ($null -in @($cancelTicks, $cancelCount, $cancelTimerId, $cancelTimerState, $preTimerId)) {
    throw 'Missing cancel-collapse timer-cancel fields.'
}
if ($cancelTicks -lt 0) { throw "Expected CANCEL_TICKS>=0. got $cancelTicks" }
if ($cancelCount -ne 0) { throw "Expected CANCEL_ENTRY_COUNT=0. got $cancelCount" }
if ($cancelTimerId -ne $preTimerId) { throw "Expected canceled timer id $preTimerId. got $cancelTimerId" }
if ($cancelTimerState -ne 3) { throw "Expected CANCEL_TIMER0_STATE=3. got $cancelTimerState" }

Write-Output 'BAREMETAL_QEMU_TIMER_CANCEL_CANCEL_COLLAPSE_PROBE=pass'
Write-Output "CANCEL_TICKS=$cancelTicks"
Write-Output "CANCEL_ENTRY_COUNT=$cancelCount"
Write-Output "CANCEL_TIMER0_ID=$cancelTimerId"
Write-Output "CANCEL_TIMER0_STATE=$cancelTimerState"
