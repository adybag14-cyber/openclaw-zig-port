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
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Mode-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

$firstPrev = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_PREV'
$firstNew = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_NEW'
$firstReason = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_REASON'
$lastPrev = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_PREV'
$lastNew = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_NEW'
$lastReason = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_REASON'
if ($firstPrev -ne 1 -or $firstNew -ne 0 -or $firstReason -ne 1 -or $lastPrev -ne 0 -or $lastNew -ne 1 -or $lastReason -ne 3) {
    throw "Unexpected overflow payloads. first=$firstPrev->$($firstNew):$firstReason last=$lastPrev->$($lastNew):$lastReason"
}

Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE_SOURCE=baremetal-qemu-mode-history-overflow-clear-probe-check.ps1'
Write-Output "FIRST_PAYLOAD=$firstPrev->$($firstNew):$firstReason"
Write-Output "LAST_PAYLOAD=$lastPrev->$($lastNew):$lastReason"
