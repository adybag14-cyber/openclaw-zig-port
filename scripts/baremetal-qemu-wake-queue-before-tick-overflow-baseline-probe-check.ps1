param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-before-tick-overflow-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild -TimeoutSeconds 90 2>&1 } else { & $probe -TimeoutSeconds 90 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue before-tick overflow probe failed with exit code $probeExitCode"
}

$wakeCycles = Extract-IntValue -Text $probeText -Name 'WAKE_CYCLES'
$taskId = Extract-IntValue -Text $probeText -Name 'TASK_ID'
$ticks = Extract-IntValue -Text $probeText -Name 'TICKS'
$preCount = Extract-IntValue -Text $probeText -Name 'PRE_COUNT'
$preHead = Extract-IntValue -Text $probeText -Name 'PRE_HEAD'
$preTail = Extract-IntValue -Text $probeText -Name 'PRE_TAIL'
$preOverflow = Extract-IntValue -Text $probeText -Name 'PRE_OVERFLOW'

if ($null -in @($wakeCycles, $taskId, $ticks, $preCount, $preHead, $preTail, $preOverflow)) {
    throw 'Missing expected baseline fields in wake-queue before-tick overflow probe output.'
}
if ($wakeCycles -ne 66) { throw "Expected WAKE_CYCLES=66. got $wakeCycles" }
if ($taskId -ne 1) { throw "Expected TASK_ID=1. got $taskId" }
if ($ticks -lt 136) { throw "Expected TICKS >= 136. got $ticks" }
if ($preCount -ne 64) { throw "Expected PRE_COUNT=64. got $preCount" }
if ($preHead -ne 2) { throw "Expected PRE_HEAD=2. got $preHead" }
if ($preTail -ne 2) { throw "Expected PRE_TAIL=2. got $preTail" }
if ($preOverflow -ne 2) { throw "Expected PRE_OVERFLOW=2. got $preOverflow" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_BASELINE_PROBE=pass'
Write-Output "WAKE_CYCLES=$wakeCycles"
Write-Output "TASK_ID=$taskId"
Write-Output "TICKS=$ticks"
Write-Output "PRE_COUNT=$preCount"
Write-Output "PRE_HEAD=$preHead"
Write-Output "PRE_TAIL=$preTail"
Write-Output "PRE_OVERFLOW=$preOverflow"
