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
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_POST_RESET_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator saturation-reset probe failed with exit code $probeExitCode"
}
$postResetFreePages = Extract-IntValue -Text $probeText -Name 'POST_RESET_FREE_PAGES'
$postResetAllocationCount = Extract-IntValue -Text $probeText -Name 'POST_RESET_ALLOCATION_COUNT'
$postResetAllocOps = Extract-IntValue -Text $probeText -Name 'POST_RESET_ALLOC_OPS'
$postResetFreeOps = Extract-IntValue -Text $probeText -Name 'POST_RESET_FREE_OPS'
$postResetBytesInUse = Extract-IntValue -Text $probeText -Name 'POST_RESET_BYTES_IN_USE'
$postResetPeakBytes = Extract-IntValue -Text $probeText -Name 'POST_RESET_PEAK_BYTES'
$postResetFirstRecordState = Extract-IntValue -Text $probeText -Name 'POST_RESET_FIRST_RECORD_STATE'
$postResetSecondRecordState = Extract-IntValue -Text $probeText -Name 'POST_RESET_SECOND_RECORD_STATE'
$postResetBitmap0 = Extract-IntValue -Text $probeText -Name 'POST_RESET_BITMAP0'
$postResetBitmap63 = Extract-IntValue -Text $probeText -Name 'POST_RESET_BITMAP63'
if ($null -in @($postResetFreePages,$postResetAllocationCount,$postResetAllocOps,$postResetFreeOps,$postResetBytesInUse,$postResetPeakBytes,$postResetFirstRecordState,$postResetSecondRecordState,$postResetBitmap0,$postResetBitmap63)) { throw 'Missing post-reset allocator saturation-reset fields.' }
if ($postResetFreePages -ne 256) { throw "Expected POST_RESET_FREE_PAGES=256. got $postResetFreePages" }
if ($postResetAllocationCount -ne 0) { throw "Expected POST_RESET_ALLOCATION_COUNT=0. got $postResetAllocationCount" }
if ($postResetAllocOps -ne 0) { throw "Expected POST_RESET_ALLOC_OPS=0. got $postResetAllocOps" }
if ($postResetFreeOps -ne 0) { throw "Expected POST_RESET_FREE_OPS=0. got $postResetFreeOps" }
if ($postResetBytesInUse -ne 0) { throw "Expected POST_RESET_BYTES_IN_USE=0. got $postResetBytesInUse" }
if ($postResetPeakBytes -ne 0) { throw "Expected POST_RESET_PEAK_BYTES=0. got $postResetPeakBytes" }
if ($postResetFirstRecordState -ne 0) { throw "Expected POST_RESET_FIRST_RECORD_STATE=0. got $postResetFirstRecordState" }
if ($postResetSecondRecordState -ne 0) { throw "Expected POST_RESET_SECOND_RECORD_STATE=0. got $postResetSecondRecordState" }
if ($postResetBitmap0 -ne 0) { throw "Expected POST_RESET_BITMAP0=0. got $postResetBitmap0" }
if ($postResetBitmap63 -ne 0) { throw "Expected POST_RESET_BITMAP63=0. got $postResetBitmap63" }
Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_POST_RESET_BASELINE_PROBE=pass'
Write-Output "POST_RESET_FREE_PAGES=$postResetFreePages"
Write-Output "POST_RESET_ALLOCATION_COUNT=$postResetAllocationCount"
Write-Output "POST_RESET_ALLOC_OPS=$postResetAllocOps"
Write-Output "POST_RESET_FREE_OPS=$postResetFreeOps"
Write-Output "POST_RESET_BYTES_IN_USE=$postResetBytesInUse"
Write-Output "POST_RESET_PEAK_BYTES=$postResetPeakBytes"
Write-Output "POST_RESET_FIRST_RECORD_STATE=$postResetFirstRecordState"
Write-Output "POST_RESET_SECOND_RECORD_STATE=$postResetSecondRecordState"
Write-Output "POST_RESET_BITMAP0=$postResetBitmap0"
Write-Output "POST_RESET_BITMAP63=$postResetBitmap63"
