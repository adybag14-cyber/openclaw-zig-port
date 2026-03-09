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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_QUERY3_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-count-snapshot probe failed with exit code $probeExitCode"
}

$query2Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_TICK'
$query3Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_TICK'
$query3VectorCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_VECTOR_COUNT'
$query3BeforeTickCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_BEFORE_TICK_COUNT'
$query3ReasonVectorCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_REASON_VECTOR_COUNT'

if ($null -in @($query2Tick, $query3Tick, $query3VectorCount, $query3BeforeTickCount, $query3ReasonVectorCount)) {
    throw 'Missing expected query3 fields in wake-queue-count-snapshot probe output.'
}
if ($query3VectorCount -ne 1) { throw "Expected QUERY3_VECTOR_COUNT=1. got $query3VectorCount" }
if ($query3BeforeTickCount -ne 5) { throw "Expected QUERY3_BEFORE_TICK_COUNT=5. got $query3BeforeTickCount" }
if ($query3ReasonVectorCount -ne 0) { throw "Expected QUERY3_REASON_VECTOR_COUNT=0. got $query3ReasonVectorCount" }
if ($query3Tick -lt $query2Tick) { throw "Expected QUERY3_TICK >= QUERY2_TICK. query2=$query2Tick query3=$query3Tick" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_QUERY3_PROBE=pass'
Write-Output "QUERY3_TICK=$query3Tick"
Write-Output "QUERY3_VECTOR_COUNT=$query3VectorCount"
Write-Output "QUERY3_BEFORE_TICK_COUNT=$query3BeforeTickCount"
Write-Output "QUERY3_REASON_VECTOR_COUNT=$query3ReasonVectorCount"
