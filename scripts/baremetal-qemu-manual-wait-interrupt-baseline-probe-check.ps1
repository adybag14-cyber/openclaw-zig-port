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
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait interrupt probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TASK_ID'
$taskPriority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TASK_PRIORITY'
$waitStateBeforeInterrupt = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_STATE_BEFORE_INTERRUPT'
$waitTaskCountBeforeInterrupt = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_TASK_COUNT_BEFORE_INTERRUPT'
$waitKindBeforeInterrupt = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_KIND_BEFORE_INTERRUPT'
if ($null -in @($taskId, $taskPriority, $waitStateBeforeInterrupt, $waitTaskCountBeforeInterrupt, $waitKindBeforeInterrupt)) {
    throw 'Missing expected baseline fields in manual-wait interrupt probe output.'
}
if ($taskId -le 0) { throw "Expected TASK_ID > 0, got $taskId" }
if ($taskPriority -ne 0) { throw "Expected TASK_PRIORITY=0, got $taskPriority" }
if ($waitStateBeforeInterrupt -ne 6) { throw "Expected WAIT_STATE_BEFORE_INTERRUPT=6, got $waitStateBeforeInterrupt" }
if ($waitTaskCountBeforeInterrupt -ne 0) { throw "Expected WAIT_TASK_COUNT_BEFORE_INTERRUPT=0, got $waitTaskCountBeforeInterrupt" }
if ($waitKindBeforeInterrupt -ne 1) { throw "Expected WAIT_KIND_BEFORE_INTERRUPT=1, got $waitKindBeforeInterrupt" }

Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output "TASK_ID=$taskId"
Write-Output "TASK_PRIORITY=$taskPriority"
Write-Output "WAIT_STATE_BEFORE_INTERRUPT=$waitStateBeforeInterrupt"
Write-Output "WAIT_TASK_COUNT_BEFORE_INTERRUPT=$waitTaskCountBeforeInterrupt"
Write-Output "WAIT_KIND_BEFORE_INTERRUPT=$waitKindBeforeInterrupt"
