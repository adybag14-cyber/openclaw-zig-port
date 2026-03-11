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
    Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_EXCEPTION_OVERFLOW_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-history-overflow probe failed with exit code $probeExitCode"
}

$count = Extract-IntValue -Text $probeText -Name 'EXCEPTION_COUNT_PHASE_B'
$historyLen = Extract-IntValue -Text $probeText -Name 'EXCEPTION_HISTORY_LEN_PHASE_B'
$overflow = Extract-IntValue -Text $probeText -Name 'EXCEPTION_HISTORY_OVERFLOW_PHASE_B'

if ($null -in @($count, $historyLen, $overflow)) {
    throw 'Missing phase B exception-overflow fields.'
}
if ($count -ne 19) { throw "Expected EXCEPTION_COUNT_PHASE_B=19. got $count" }
if ($historyLen -ne 16) { throw "Expected EXCEPTION_HISTORY_LEN_PHASE_B=16. got $historyLen" }
if ($overflow -ne 3) { throw "Expected EXCEPTION_HISTORY_OVERFLOW_PHASE_B=3. got $overflow" }

Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_EXCEPTION_OVERFLOW_PROBE=pass'
Write-Output "EXCEPTION_COUNT_PHASE_B=$count"
Write-Output "EXCEPTION_HISTORY_LEN_PHASE_B=$historyLen"
Write-Output "EXCEPTION_HISTORY_OVERFLOW_PHASE_B=$overflow"
