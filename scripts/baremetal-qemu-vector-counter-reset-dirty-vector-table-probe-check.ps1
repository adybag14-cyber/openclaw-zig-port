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
    Write-Output "BAREMETAL_QEMU_VECTOR_COUNTER_RESET_DIRTY_VECTOR_TABLE_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-counter-reset probe failed with exit code $probeExitCode"
}

$expect = @{
    'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PRE_INT_VECTOR10' = 2
    'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PRE_INT_VECTOR200' = 1
    'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PRE_INT_VECTOR14' = 1
    'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PRE_EXC_VECTOR10' = 2
    'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PRE_EXC_VECTOR14' = 1
}
foreach ($name in $expect.Keys) {
    $actual = Extract-IntValue -Text $probeText -Name $name
    if ($null -eq $actual) { throw "Missing $name in vector-counter-reset output." }
    if ($actual -ne $expect[$name]) { throw "Unexpected $name value: expected $($expect[$name]), got $actual" }
}

Write-Output 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_DIRTY_VECTOR_TABLE_PROBE=pass'
Write-Output 'PRE_INT_VECTOR10=2'
Write-Output 'PRE_INT_VECTOR200=1'
Write-Output 'PRE_INT_VECTOR14=1'
Write-Output 'PRE_EXC_VECTOR10=2'
Write-Output 'PRE_EXC_VECTOR14=1'
