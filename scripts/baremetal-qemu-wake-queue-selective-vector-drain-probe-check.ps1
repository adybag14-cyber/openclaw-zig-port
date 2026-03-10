param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-selective-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_VECTOR_DRAIN_PROBE=skipped'

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE=skipped') {
    Write-Output $skipToken
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue selective probe failed with exit code $probeExitCode"
}

$postVectorLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_POST_VECTOR_LEN'
$postVectorTask1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_POST_VECTOR_TASK1'
$postVectorCount13 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_POST_VECTOR_COUNT_13'
$postVectorCount31 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_POST_VECTOR_COUNT_31'
if ($null -in @($postVectorLen,$postVectorTask1,$postVectorCount13,$postVectorCount31)) {
    throw 'Missing expected vector-drain fields in wake-queue selective probe output.'
}
if ($postVectorLen -ne 3) { throw "Expected POST_VECTOR_LEN=3. got $postVectorLen" }
if ($postVectorTask1 -ne 4) { throw "Expected POST_VECTOR_TASK1=4. got $postVectorTask1" }
if ($postVectorCount13 -ne 0 -or $postVectorCount31 -ne 1) {
    throw "Unexpected post-vector counts: 13=$postVectorCount13 31=$postVectorCount31"
}

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_VECTOR_DRAIN_PROBE=pass'
Write-Output "POST_VECTOR_LEN=$postVectorLen"
Write-Output "POST_VECTOR_TASK1=$postVectorTask1"
Write-Output "POST_VECTOR_COUNT_13=$postVectorCount13"
Write-Output "POST_VECTOR_COUNT_31=$postVectorCount31"
