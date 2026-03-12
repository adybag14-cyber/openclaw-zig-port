param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$invoke = @{ TimeoutSeconds = $TimeoutSeconds }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_RESTART_EVENT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_RESTART_EVENT_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Mode-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

$restartLen = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_LEN'
$restartHead = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_HEAD'
$restartOverflow = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_OVERFLOW'
$restartSeq = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SEQ'
$restartFirstSeq = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_SEQ'
$restartFirstPrev = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_PREV'
$restartFirstNew = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_NEW'
$restartFirstReason = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_REASON'
$restartSecondSeq = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_SEQ'
$restartSecondPrev = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_PREV'
$restartSecondNew = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_NEW'
$restartSecondReason = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_REASON'
if (
    $restartLen -ne 2 -or $restartHead -ne 2 -or $restartOverflow -ne 0 -or $restartSeq -ne 2 -or
    $restartFirstSeq -ne 1 -or $restartFirstPrev -ne 1 -or $restartFirstNew -ne 0 -or $restartFirstReason -ne 1 -or
    $restartSecondSeq -ne 2 -or $restartSecondPrev -ne 0 -or $restartSecondNew -ne 1 -or $restartSecondReason -ne 3
) {
    throw "Unexpected restart event state. restartLen=$restartLen restartHead=$restartHead restartOverflow=$restartOverflow restartSeq=$restartSeq first=$restartFirstSeq/$restartFirstPrev->$($restartFirstNew):$restartFirstReason second=$restartSecondSeq/$restartSecondPrev->$($restartSecondNew):$restartSecondReason"
}

Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_RESTART_EVENT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_RESTART_EVENT_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
Write-Output "RESTART_LEN=$restartLen"
Write-Output "RESTART_HEAD=$restartHead"
Write-Output "RESTART_OVERFLOW=$restartOverflow"
Write-Output "RESTART_SEQ=$restartSeq"
Write-Output "RESTART_FIRST_SEQ=$restartFirstSeq"
Write-Output "RESTART_FIRST_PAYLOAD=$restartFirstPrev->$($restartFirstNew):$restartFirstReason"
Write-Output "RESTART_SECOND_SEQ=$restartSecondSeq"
Write-Output "RESTART_SECOND_PAYLOAD=$restartSecondPrev->$($restartSecondNew):$restartSecondReason"
