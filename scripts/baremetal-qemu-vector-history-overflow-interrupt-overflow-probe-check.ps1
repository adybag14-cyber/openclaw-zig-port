param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-vector-history-overflow-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_INTERRUPT_OVERFLOW_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-history-overflow probe failed with exit code $probeExitCode"
}

$count = Extract-IntValue -Text $probeText -Name 'INTERRUPT_COUNT_PHASE_A'
$vectorCount = Extract-IntValue -Text $probeText -Name 'INTERRUPT_VECTOR_200_COUNT_PHASE_A'
$historyLen = Extract-IntValue -Text $probeText -Name 'INTERRUPT_HISTORY_LEN_PHASE_A'
$overflow = Extract-IntValue -Text $probeText -Name 'INTERRUPT_HISTORY_OVERFLOW_PHASE_A'

if ($null -in @($count, $vectorCount, $historyLen, $overflow)) {
    throw 'Missing phase A interrupt-overflow fields.'
}
if ($count -ne 35) { throw "Expected INTERRUPT_COUNT_PHASE_A=35. got $count" }
if ($vectorCount -ne 35) { throw "Expected INTERRUPT_VECTOR_200_COUNT_PHASE_A=35. got $vectorCount" }
if ($historyLen -ne 32) { throw "Expected INTERRUPT_HISTORY_LEN_PHASE_A=32. got $historyLen" }
if ($overflow -ne 3) { throw "Expected INTERRUPT_HISTORY_OVERFLOW_PHASE_A=3. got $overflow" }

Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_INTERRUPT_OVERFLOW_PROBE=pass'
Write-Output "INTERRUPT_COUNT_PHASE_A=$count"
Write-Output "INTERRUPT_VECTOR_200_COUNT_PHASE_A=$vectorCount"
Write-Output "INTERRUPT_HISTORY_LEN_PHASE_A=$historyLen"
Write-Output "INTERRUPT_HISTORY_OVERFLOW_PHASE_A=$overflow"
