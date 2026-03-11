param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-manual-wait-interrupt-probe-check.ps1"

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
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_BLOCKED_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_BLOCKED_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait interrupt probe failed with exit code $probeExitCode"
}

$afterInterruptTaskState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_TASK_STATE'
$afterInterruptTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_TASK_COUNT'
$afterInterruptWaitKind = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_WAIT_KIND'
$afterInterruptWakeQueueLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_WAKE_QUEUE_LEN'
if ($null -in @($afterInterruptTaskState, $afterInterruptTaskCount, $afterInterruptWaitKind, $afterInterruptWakeQueueLen)) {
    throw 'Missing expected after-interrupt blocked fields in manual-wait interrupt probe output.'
}
if ($afterInterruptTaskState -ne 6) { throw "Expected AFTER_INTERRUPT_TASK_STATE=6, got $afterInterruptTaskState" }
if ($afterInterruptTaskCount -ne 0) { throw "Expected AFTER_INTERRUPT_TASK_COUNT=0, got $afterInterruptTaskCount" }
if ($afterInterruptWaitKind -ne 1) { throw "Expected AFTER_INTERRUPT_WAIT_KIND=1, got $afterInterruptWaitKind" }
if ($afterInterruptWakeQueueLen -ne 0) { throw "Expected AFTER_INTERRUPT_WAKE_QUEUE_LEN=0, got $afterInterruptWakeQueueLen" }

Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_BLOCKED_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_BLOCKED_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output "AFTER_INTERRUPT_TASK_STATE=$afterInterruptTaskState"
Write-Output "AFTER_INTERRUPT_TASK_COUNT=$afterInterruptTaskCount"
Write-Output "AFTER_INTERRUPT_WAIT_KIND=$afterInterruptWaitKind"
Write-Output "AFTER_INTERRUPT_WAKE_QUEUE_LEN=$afterInterruptWakeQueueLen"
