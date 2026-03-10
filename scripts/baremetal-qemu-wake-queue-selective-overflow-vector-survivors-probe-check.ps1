param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-selective-overflow-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild -TimeoutSeconds 90 2>&1 } else { & $probe -TimeoutSeconds 90 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_VECTOR_SURVIVORS_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue-selective-overflow probe failed with exit code $probeExitCode"
}

$firstSeq = Extract-IntValue -Text $probeText -Name 'POST_VECTOR_FIRST_SEQ'
$firstVector = Extract-IntValue -Text $probeText -Name 'POST_VECTOR_FIRST_VECTOR'
$retainedSeq = Extract-IntValue -Text $probeText -Name 'POST_VECTOR_REMAINING_SEQ'
$retainedVector = Extract-IntValue -Text $probeText -Name 'POST_VECTOR_REMAINING_VECTOR'
$lastSeq = Extract-IntValue -Text $probeText -Name 'POST_VECTOR_LAST_SEQ'
$lastVector = Extract-IntValue -Text $probeText -Name 'POST_VECTOR_LAST_VECTOR'

if ($null -in @($firstSeq, $firstVector, $retainedSeq, $retainedVector, $lastSeq, $lastVector)) {
    throw 'Missing expected post-vector survivor fields in wake-queue-selective-overflow probe output.'
}
if ($firstSeq -ne 4 -or $firstVector -ne 31 -or $retainedSeq -ne 65 -or $retainedVector -ne 13 -or $lastSeq -ne 66 -or $lastVector -ne 31) {
    throw 'Unexpected POST_VECTOR survivor ordering.'
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_OVERFLOW_VECTOR_SURVIVORS_PROBE=pass'
Write-Output "POST_VECTOR_FIRST_SEQ=$firstSeq"
Write-Output "POST_VECTOR_FIRST_VECTOR=$firstVector"
Write-Output "POST_VECTOR_REMAINING_SEQ=$retainedSeq"
Write-Output "POST_VECTOR_REMAINING_VECTOR=$retainedVector"
Write-Output "POST_VECTOR_LAST_SEQ=$lastSeq"
Write-Output "POST_VECTOR_LAST_VECTOR=$lastVector"
