param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-before-tick-overflow-probe-check.ps1"

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
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_FIRST_SURVIVOR_WINDOW_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue before-tick overflow probe failed with exit code $probeExitCode"
}

$postFirstHead = Extract-IntValue -Text $probeText -Name 'POST_FIRST_HEAD'
$postFirstTail = Extract-IntValue -Text $probeText -Name 'POST_FIRST_TAIL'
$postFirstOverflow = Extract-IntValue -Text $probeText -Name 'POST_FIRST_OVERFLOW'
$postFirstSeq = Extract-IntValue -Text $probeText -Name 'POST_FIRST_SEQ'
$postFirstCutoffSeq = Extract-IntValue -Text $probeText -Name 'POST_FIRST_CUTOFF_SEQ'
$postFirstLastSeq = Extract-IntValue -Text $probeText -Name 'POST_FIRST_LAST_SEQ'

if ($null -in @($postFirstHead, $postFirstTail, $postFirstOverflow, $postFirstSeq, $postFirstCutoffSeq, $postFirstLastSeq)) {
    throw 'Missing expected first survivor-window fields in wake-queue before-tick overflow probe output.'
}
if ($postFirstHead -ne 32) { throw "Expected POST_FIRST_HEAD=32. got $postFirstHead" }
if ($postFirstTail -ne 0) { throw "Expected POST_FIRST_TAIL=0. got $postFirstTail" }
if ($postFirstOverflow -ne 2) { throw "Expected POST_FIRST_OVERFLOW=2. got $postFirstOverflow" }
if ($postFirstSeq -ne 35) { throw "Expected POST_FIRST_SEQ=35. got $postFirstSeq" }
if ($postFirstCutoffSeq -ne 65) { throw "Expected POST_FIRST_CUTOFF_SEQ=65. got $postFirstCutoffSeq" }
if ($postFirstLastSeq -ne 66) { throw "Expected POST_FIRST_LAST_SEQ=66. got $postFirstLastSeq" }

Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_BEFORE_TICK_OVERFLOW_FIRST_SURVIVOR_WINDOW_PROBE=pass'
Write-Output "POST_FIRST_HEAD=$postFirstHead"
Write-Output "POST_FIRST_TAIL=$postFirstTail"
Write-Output "POST_FIRST_OVERFLOW=$postFirstOverflow"
Write-Output "POST_FIRST_SEQ=$postFirstSeq"
Write-Output "POST_FIRST_CUTOFF_SEQ=$postFirstCutoffSeq"
Write-Output "POST_FIRST_LAST_SEQ=$postFirstLastSeq"
