param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-allocator-saturation-reset-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_FRESH_RESTART_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator saturation-reset probe failed with exit code $probeExitCode"
}
$freshPtr = Extract-IntValue -Text $probeText -Name 'FRESH_PTR'
$freshPageLen = Extract-IntValue -Text $probeText -Name 'FRESH_PAGE_LEN'
$freshAllocationCount = Extract-IntValue -Text $probeText -Name 'FRESH_ALLOCATION_COUNT'
$freshAllocOps = Extract-IntValue -Text $probeText -Name 'FRESH_ALLOC_OPS'
$freshBytesInUse = Extract-IntValue -Text $probeText -Name 'FRESH_BYTES_IN_USE'
$freshPeakBytes = Extract-IntValue -Text $probeText -Name 'FRESH_PEAK_BYTES'
$freshLastAllocPtr = Extract-IntValue -Text $probeText -Name 'FRESH_LAST_ALLOC_PTR'
$freshLastAllocSize = Extract-IntValue -Text $probeText -Name 'FRESH_LAST_ALLOC_SIZE'
$secondRecordState = Extract-IntValue -Text $probeText -Name 'SECOND_RECORD_STATE'
if ($null -in @($freshPtr,$freshPageLen,$freshAllocationCount,$freshAllocOps,$freshBytesInUse,$freshPeakBytes,$freshLastAllocPtr,$freshLastAllocSize,$secondRecordState)) { throw 'Missing fresh-restart allocator saturation-reset fields.' }
if ($freshPtr -ne 1048576) { throw "Expected FRESH_PTR=1048576. got $freshPtr" }
if ($freshPageLen -ne 2) { throw "Expected FRESH_PAGE_LEN=2. got $freshPageLen" }
if ($freshAllocationCount -ne 1) { throw "Expected FRESH_ALLOCATION_COUNT=1. got $freshAllocationCount" }
if ($freshAllocOps -ne 1) { throw "Expected FRESH_ALLOC_OPS=1. got $freshAllocOps" }
if ($freshBytesInUse -ne 8192) { throw "Expected FRESH_BYTES_IN_USE=8192. got $freshBytesInUse" }
if ($freshPeakBytes -ne 8192) { throw "Expected FRESH_PEAK_BYTES=8192. got $freshPeakBytes" }
if ($freshLastAllocPtr -ne $freshPtr) { throw "Expected FRESH_LAST_ALLOC_PTR=$freshPtr. got $freshLastAllocPtr" }
if ($freshLastAllocSize -ne 8192) { throw "Expected FRESH_LAST_ALLOC_SIZE=8192. got $freshLastAllocSize" }
if ($secondRecordState -ne 0) { throw "Expected SECOND_RECORD_STATE=0. got $secondRecordState" }
Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_FRESH_RESTART_PROBE=pass'
Write-Output "FRESH_PTR=$freshPtr"
Write-Output "FRESH_PAGE_LEN=$freshPageLen"
Write-Output "FRESH_ALLOCATION_COUNT=$freshAllocationCount"
Write-Output "FRESH_ALLOC_OPS=$freshAllocOps"
Write-Output "FRESH_BYTES_IN_USE=$freshBytesInUse"
Write-Output "FRESH_PEAK_BYTES=$freshPeakBytes"
Write-Output "FRESH_LAST_ALLOC_PTR=$freshLastAllocPtr"
Write-Output "FRESH_LAST_ALLOC_SIZE=$freshLastAllocSize"
Write-Output "SECOND_RECORD_STATE=$secondRecordState"
