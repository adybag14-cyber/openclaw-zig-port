param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-selective-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_BASELINE_PROBE=skipped'

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE=skipped') {
    Write-Output $skipToken
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue selective probe failed with exit code $probeExitCode"
}

$preLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_LEN'
$preTask0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_TASK0'
$preTask1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_TASK1'
$preTask2 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_TASK2'
$preTask3 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_TASK3'
$preTask4 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_TASK4'
$preVectorCount13 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_VECTOR_COUNT_13'
$preVectorCount31 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_PRE_VECTOR_COUNT_31'
if ($null -in @($preLen,$preTask0,$preTask1,$preTask2,$preTask3,$preTask4,$preVectorCount13,$preVectorCount31)) {
    throw 'Missing expected baseline fields in wake-queue selective probe output.'
}
if ($preLen -ne 5) { throw "Expected PRE_LEN=5. got $preLen" }
if ($preTask0 -ne 1 -or $preTask1 -ne 2 -or $preTask2 -ne 3 -or $preTask3 -ne 4 -or $preTask4 -ne 5) {
    throw "Unexpected baseline task ordering: $preTask0,$preTask1,$preTask2,$preTask3,$preTask4"
}
if ($preVectorCount13 -ne 2 -or $preVectorCount31 -ne 1) {
    throw "Unexpected baseline vector counts: 13=$preVectorCount13 31=$preVectorCount31"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_BASELINE_PROBE=pass'
Write-Output "PRE_LEN=$preLen"
Write-Output "PRE_TASK0=$preTask0"
Write-Output "PRE_TASK1=$preTask1"
Write-Output "PRE_TASK2=$preTask2"
Write-Output "PRE_TASK3=$preTask3"
Write-Output "PRE_TASK4=$preTask4"
Write-Output "PRE_VECTOR_COUNT_13=$preVectorCount13"
Write-Output "PRE_VECTOR_COUNT_31=$preVectorCount31"
