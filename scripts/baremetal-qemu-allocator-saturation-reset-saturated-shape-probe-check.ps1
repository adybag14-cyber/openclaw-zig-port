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
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_SATURATED_SHAPE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator saturation-reset probe failed with exit code $probeExitCode"
}
$preResetAllocationCount = Extract-IntValue -Text $probeText -Name 'PRE_RESET_ALLOCATION_COUNT'
$preResetFreePages = Extract-IntValue -Text $probeText -Name 'PRE_RESET_FREE_PAGES'
$preResetAllocOps = Extract-IntValue -Text $probeText -Name 'PRE_RESET_ALLOC_OPS'
$preResetBytesInUse = Extract-IntValue -Text $probeText -Name 'PRE_RESET_BYTES_IN_USE'
$preResetPeakBytes = Extract-IntValue -Text $probeText -Name 'PRE_RESET_PEAK_BYTES'
if ($null -in @($preResetAllocationCount,$preResetFreePages,$preResetAllocOps,$preResetBytesInUse,$preResetPeakBytes)) { throw 'Missing saturated-shape allocator saturation-reset fields.' }
if ($preResetAllocationCount -ne 64) { throw "Expected PRE_RESET_ALLOCATION_COUNT=64. got $preResetAllocationCount" }
if ($preResetFreePages -ne 192) { throw "Expected PRE_RESET_FREE_PAGES=192. got $preResetFreePages" }
if ($preResetAllocOps -ne 64) { throw "Expected PRE_RESET_ALLOC_OPS=64. got $preResetAllocOps" }
if ($preResetBytesInUse -ne 262144) { throw "Expected PRE_RESET_BYTES_IN_USE=262144. got $preResetBytesInUse" }
if ($preResetPeakBytes -ne 262144) { throw "Expected PRE_RESET_PEAK_BYTES=262144. got $preResetPeakBytes" }
Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_SATURATED_SHAPE_PROBE=pass'
Write-Output "PRE_RESET_ALLOCATION_COUNT=$preResetAllocationCount"
Write-Output "PRE_RESET_FREE_PAGES=$preResetFreePages"
Write-Output "PRE_RESET_ALLOC_OPS=$preResetAllocOps"
Write-Output "PRE_RESET_BYTES_IN_USE=$preResetBytesInUse"
Write-Output "PRE_RESET_PEAK_BYTES=$preResetPeakBytes"
