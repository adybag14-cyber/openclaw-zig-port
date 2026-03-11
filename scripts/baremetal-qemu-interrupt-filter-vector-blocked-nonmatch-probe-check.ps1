param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-filter-probe-check.ps1"

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_FILTER_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_FILTER_VECTOR_BLOCKED_NONMATCH_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_FILTER_VECTOR_BLOCKED_NONMATCH_PROBE_SOURCE=baremetal-qemu-interrupt-filter-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying interrupt-filter probe failed with exit code $probeExitCode"
}

$vecWaitCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_COUNT_BEFORE_MATCH'
$vecWaitKind = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_KIND_BEFORE_MATCH'
$vecWaitVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_VECTOR_BEFORE_MATCH'
$vecWaitTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_TASK_COUNT_BEFORE_MATCH'
$vecWaitTaskState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_TASK_STATE_BEFORE_MATCH'
$vecWaitWakeQueueLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_WAKE_QUEUE_LEN_BEFORE_MATCH'
if ($null -in @($vecWaitCount, $vecWaitKind, $vecWaitVector, $vecWaitTaskCount, $vecWaitTaskState, $vecWaitWakeQueueLen)) { throw 'Missing vector-blocked fields in interrupt-filter probe output.' }
if ($vecWaitCount -ne 1) { throw "Expected VEC_WAIT_COUNT_BEFORE_MATCH=1, got $vecWaitCount" }
if ($vecWaitKind -ne 4) { throw "Expected VEC_WAIT_KIND_BEFORE_MATCH=4, got $vecWaitKind" }
if ($vecWaitVector -ne 13) { throw "Expected VEC_WAIT_VECTOR_BEFORE_MATCH=13, got $vecWaitVector" }
if ($vecWaitTaskCount -ne 1) { throw "Expected VEC_WAIT_TASK_COUNT_BEFORE_MATCH=1, got $vecWaitTaskCount" }
if ($vecWaitTaskState -ne 6) { throw "Expected VEC_WAIT_TASK_STATE_BEFORE_MATCH=6, got $vecWaitTaskState" }
if ($vecWaitWakeQueueLen -ne 0) { throw "Expected VEC_WAIT_WAKE_QUEUE_LEN_BEFORE_MATCH=0, got $vecWaitWakeQueueLen" }
Write-Output 'BAREMETAL_QEMU_INTERRUPT_FILTER_VECTOR_BLOCKED_NONMATCH_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_FILTER_VECTOR_BLOCKED_NONMATCH_PROBE_SOURCE=baremetal-qemu-interrupt-filter-probe-check.ps1'
Write-Output "VEC_WAIT_COUNT_BEFORE_MATCH=$vecWaitCount"
Write-Output "VEC_WAIT_KIND_BEFORE_MATCH=$vecWaitKind"
Write-Output "VEC_WAIT_VECTOR_BEFORE_MATCH=$vecWaitVector"
Write-Output "VEC_WAIT_TASK_COUNT_BEFORE_MATCH=$vecWaitTaskCount"
Write-Output "VEC_WAIT_TASK_STATE_BEFORE_MATCH=$vecWaitTaskState"
Write-Output "VEC_WAIT_WAKE_QUEUE_LEN_BEFORE_MATCH=$vecWaitWakeQueueLen"
