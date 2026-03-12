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
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_WINDOW_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_WINDOW_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Mode-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

$overflowCount = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_OVERFLOW_COUNT'
$overflowHead = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_OVERFLOW_HEAD'
$firstSeq = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_SEQ'
$lastSeq = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_SEQ'
if ($overflowCount -ne 2 -or $overflowHead -ne 2 -or $firstSeq -ne 3 -or $lastSeq -ne 66) {
    throw "Unexpected overflow window. overflow=$overflowCount head=$overflowHead first=$firstSeq last=$lastSeq"
}

Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_WINDOW_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_WINDOW_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
Write-Output "OVERFLOW_COUNT=$overflowCount"
Write-Output "OVERFLOW_HEAD=$overflowHead"
Write-Output "FIRST_SEQ=$firstSeq"
Write-Output "LAST_SEQ=$lastSeq"
