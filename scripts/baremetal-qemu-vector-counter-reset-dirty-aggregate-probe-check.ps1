param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-vector-counter-reset-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_VECTOR_COUNTER_RESET_DIRTY_AGGREGATE_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-counter-reset probe failed with exit code $probeExitCode"
}

$preInterrupt = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PRE_INTERRUPT_COUNT'
$preException = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PRE_EXCEPTION_COUNT'
if ($null -in @($preInterrupt, $preException)) {
    throw 'Missing dirty aggregate fields in vector-counter-reset output.'
}
if ($preInterrupt -ne 4 -or $preException -ne 3) {
    throw "Unexpected dirty aggregate baseline. interrupt=$preInterrupt exception=$preException"
}

Write-Output 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_DIRTY_AGGREGATE_PROBE=pass'
Write-Output "PRE_INTERRUPT_COUNT=$preInterrupt"
Write-Output "PRE_EXCEPTION_COUNT=$preException"
