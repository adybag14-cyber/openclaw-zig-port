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
    Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_VECTOR_TELEMETRY_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-history-overflow probe failed with exit code $probeExitCode"
}

$interruptCount = Extract-IntValue -Text $probeText -Name 'INTERRUPT_COUNT_PHASE_B'
$interruptVectorCount = Extract-IntValue -Text $probeText -Name 'INTERRUPT_VECTOR_13_COUNT_PHASE_B'
$exceptionVectorCount = Extract-IntValue -Text $probeText -Name 'EXCEPTION_VECTOR_13_COUNT_PHASE_B'
$interruptLastVector = Extract-IntValue -Text $probeText -Name 'LAST_INTERRUPT_VECTOR_PHASE_B'
$exceptionLastVector = Extract-IntValue -Text $probeText -Name 'LAST_EXCEPTION_VECTOR_PHASE_B'
$lastExceptionCode = Extract-IntValue -Text $probeText -Name 'LAST_EXCEPTION_CODE_PHASE_B'

if ($null -in @($interruptCount, $interruptVectorCount, $exceptionVectorCount, $interruptLastVector, $exceptionLastVector, $lastExceptionCode)) {
    throw 'Missing phase B vector-telemetry fields.'
}
if ($interruptCount -ne 19) { throw "Expected INTERRUPT_COUNT_PHASE_B=19. got $interruptCount" }
if ($interruptVectorCount -ne 19) { throw "Expected INTERRUPT_VECTOR_13_COUNT_PHASE_B=19. got $interruptVectorCount" }
if ($exceptionVectorCount -ne 19) { throw "Expected EXCEPTION_VECTOR_13_COUNT_PHASE_B=19. got $exceptionVectorCount" }
if ($interruptLastVector -ne 13) { throw "Expected LAST_INTERRUPT_VECTOR_PHASE_B=13. got $interruptLastVector" }
if ($exceptionLastVector -ne 13) { throw "Expected LAST_EXCEPTION_VECTOR_PHASE_B=13. got $exceptionLastVector" }
if ($lastExceptionCode -ne 118) { throw "Expected LAST_EXCEPTION_CODE_PHASE_B=118. got $lastExceptionCode" }

Write-Output 'BAREMETAL_QEMU_VECTOR_HISTORY_OVERFLOW_VECTOR_TELEMETRY_PROBE=pass'
Write-Output "INTERRUPT_COUNT_PHASE_B=$interruptCount"
Write-Output "INTERRUPT_VECTOR_13_COUNT_PHASE_B=$interruptVectorCount"
Write-Output "EXCEPTION_VECTOR_13_COUNT_PHASE_B=$exceptionVectorCount"
Write-Output "LAST_INTERRUPT_VECTOR_PHASE_B=$interruptLastVector"
Write-Output "LAST_EXCEPTION_VECTOR_PHASE_B=$exceptionLastVector"
Write-Output "LAST_EXCEPTION_CODE_PHASE_B=$lastExceptionCode"
