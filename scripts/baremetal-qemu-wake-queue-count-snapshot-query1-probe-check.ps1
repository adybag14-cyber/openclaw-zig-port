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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_QUERY1_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-count-snapshot probe failed with exit code $probeExitCode"
}

$query1Tick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_TICK'
$query1VectorCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_VECTOR_COUNT'
$query1BeforeTickCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_BEFORE_TICK_COUNT'
$query1ReasonVectorCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_REASON_VECTOR_COUNT'
$preOldestTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_OLDEST_TICK'
$preNewestTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_NEWEST_TICK'

if ($null -in @($query1Tick, $query1VectorCount, $query1BeforeTickCount, $query1ReasonVectorCount, $preOldestTick, $preNewestTick)) {
    throw 'Missing expected query1 fields in wake-queue-count-snapshot probe output.'
}
if ($query1VectorCount -ne 2) { throw "Expected QUERY1_VECTOR_COUNT=2. got $query1VectorCount" }
if ($query1BeforeTickCount -ne 2) { throw "Expected QUERY1_BEFORE_TICK_COUNT=2. got $query1BeforeTickCount" }
if ($query1ReasonVectorCount -ne 2) { throw "Expected QUERY1_REASON_VECTOR_COUNT=2. got $query1ReasonVectorCount" }
if ($query1Tick -lt $preOldestTick -or $query1Tick -gt $preNewestTick) {
    throw "Expected QUERY1_TICK within baseline range. oldest=$preOldestTick query1=$query1Tick newest=$preNewestTick"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_QUERY1_PROBE=pass'
Write-Output "QUERY1_TICK=$query1Tick"
Write-Output "QUERY1_VECTOR_COUNT=$query1VectorCount"
Write-Output "QUERY1_BEFORE_TICK_COUNT=$query1BeforeTickCount"
Write-Output "QUERY1_REASON_VECTOR_COUNT=$query1ReasonVectorCount"
