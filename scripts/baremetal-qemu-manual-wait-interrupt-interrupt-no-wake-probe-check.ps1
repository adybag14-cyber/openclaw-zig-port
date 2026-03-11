param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-manual-wait-interrupt-probe-check.ps1'

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_INTERRUPT_NO_WAKE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_INTERRUPT_NO_WAKE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait-interrupt probe failed with exit code $probeExitCode"
}

$taskState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_TASK_STATE'
$taskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_TASK_COUNT'
$waitKind = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_WAIT_KIND'
$wakeQueueLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_WAKE_QUEUE_LEN'
$interruptCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_INTERRUPT_COUNT'
$lastVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_LAST_VECTOR'
if ($null -in @($taskState, $taskCount, $waitKind, $wakeQueueLen, $interruptCount, $lastVector)) { throw 'Missing interrupt-no-wake fields in manual-wait-interrupt probe output.' }
if ($taskState -ne 6) { throw "Expected AFTER_INTERRUPT_TASK_STATE=6, got $taskState" }
if ($taskCount -ne 0) { throw "Expected AFTER_INTERRUPT_TASK_COUNT=0, got $taskCount" }
if ($waitKind -ne 1) { throw "Expected AFTER_INTERRUPT_WAIT_KIND=1, got $waitKind" }
if ($wakeQueueLen -ne 0) { throw "Expected AFTER_INTERRUPT_WAKE_QUEUE_LEN=0, got $wakeQueueLen" }
if ($interruptCount -lt 1) { throw "Expected AFTER_INTERRUPT_INTERRUPT_COUNT >= 1, got $interruptCount" }
if ($lastVector -ne 44) { throw "Expected AFTER_INTERRUPT_LAST_VECTOR=44, got $lastVector" }
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_INTERRUPT_NO_WAKE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_INTERRUPT_NO_WAKE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output 'AFTER_INTERRUPT_TASK_STATE=6'
Write-Output 'AFTER_INTERRUPT_TASK_COUNT=0'
Write-Output 'AFTER_INTERRUPT_WAIT_KIND=1'
Write-Output 'AFTER_INTERRUPT_WAKE_QUEUE_LEN=0'
Write-Output "AFTER_INTERRUPT_INTERRUPT_COUNT=$interruptCount"
Write-Output 'AFTER_INTERRUPT_LAST_VECTOR=44'
