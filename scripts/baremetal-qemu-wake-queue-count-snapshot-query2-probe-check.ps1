param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-count-snapshot-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_QUERY2_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-count-snapshot probe failed with exit code $probeExitCode"
}

$query1Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_TICK'
$query2Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_TICK'
$query2VectorCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_VECTOR_COUNT'
$query2BeforeTickCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_BEFORE_TICK_COUNT'
$query2ReasonVectorCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_REASON_VECTOR_COUNT'

if ($null -in @($query1Tick, $query2Tick, $query2VectorCount, $query2BeforeTickCount, $query2ReasonVectorCount)) {
    throw 'Missing expected query2 fields in wake-queue-count-snapshot probe output.'
}
if ($query2VectorCount -ne 1) { throw "Expected QUERY2_VECTOR_COUNT=1. got $query2VectorCount" }
if ($query2BeforeTickCount -ne 4) { throw "Expected QUERY2_BEFORE_TICK_COUNT=4. got $query2BeforeTickCount" }
if ($query2ReasonVectorCount -ne 1) { throw "Expected QUERY2_REASON_VECTOR_COUNT=1. got $query2ReasonVectorCount" }
if ($query2Tick -lt $query1Tick) { throw "Expected QUERY2_TICK >= QUERY1_TICK. query1=$query1Tick query2=$query2Tick" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_QUERY2_PROBE=pass'
Write-Output "QUERY2_TICK=$query2Tick"
Write-Output "QUERY2_VECTOR_COUNT=$query2VectorCount"
Write-Output "QUERY2_BEFORE_TICK_COUNT=$query2BeforeTickCount"
Write-Output "QUERY2_REASON_VECTOR_COUNT=$query2ReasonVectorCount"
