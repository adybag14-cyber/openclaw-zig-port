param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-selective-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_REASON_DRAIN_PROBE=skipped'

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

$postReasonLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_POST_REASON_LEN'
$postReasonTask1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_PROBE_POST_REASON_TASK1'
if ($null -in @($postReasonLen,$postReasonTask1)) {
    throw 'Missing expected reason-drain fields in wake-queue selective probe output.'
}
if ($postReasonLen -ne 4) { throw "Expected POST_REASON_LEN=4. got $postReasonLen" }
if ($postReasonTask1 -ne 3) { throw "Expected POST_REASON_TASK1=3. got $postReasonTask1" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_SELECTIVE_REASON_DRAIN_PROBE=pass'
Write-Output "POST_REASON_LEN=$postReasonLen"
Write-Output "POST_REASON_TASK1=$postReasonTask1"
