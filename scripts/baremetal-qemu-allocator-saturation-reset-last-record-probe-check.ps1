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
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_LAST_RECORD_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator saturation-reset probe failed with exit code $probeExitCode"
}
$preResetFirstRecordState = Extract-IntValue -Text $probeText -Name 'PRE_RESET_FIRST_RECORD_STATE'
$preResetLastAllocPtr = Extract-IntValue -Text $probeText -Name 'PRE_RESET_LAST_ALLOC_PTR'
$preResetLastRecordPtr = Extract-IntValue -Text $probeText -Name 'PRE_RESET_LAST_RECORD_PTR'
$preResetLastRecordPageStart = Extract-IntValue -Text $probeText -Name 'PRE_RESET_LAST_RECORD_PAGE_START'
if ($null -in @($preResetFirstRecordState,$preResetLastAllocPtr,$preResetLastRecordPtr,$preResetLastRecordPageStart)) { throw 'Missing last-record allocator saturation-reset fields.' }
if ($preResetFirstRecordState -ne 1) { throw "Expected PRE_RESET_FIRST_RECORD_STATE=1. got $preResetFirstRecordState" }
if ($preResetLastAllocPtr -ne 1306624) { throw "Expected PRE_RESET_LAST_ALLOC_PTR=1306624. got $preResetLastAllocPtr" }
if ($preResetLastRecordPtr -ne $preResetLastAllocPtr) { throw "Expected PRE_RESET_LAST_RECORD_PTR=$preResetLastAllocPtr. got $preResetLastRecordPtr" }
if ($preResetLastRecordPageStart -ne 63) { throw "Expected PRE_RESET_LAST_RECORD_PAGE_START=63. got $preResetLastRecordPageStart" }
Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_LAST_RECORD_PROBE=pass'
Write-Output "PRE_RESET_FIRST_RECORD_STATE=$preResetFirstRecordState"
Write-Output "PRE_RESET_LAST_ALLOC_PTR=$preResetLastAllocPtr"
Write-Output "PRE_RESET_LAST_RECORD_PTR=$preResetLastRecordPtr"
Write-Output "PRE_RESET_LAST_RECORD_PAGE_START=$preResetLastRecordPageStart"
