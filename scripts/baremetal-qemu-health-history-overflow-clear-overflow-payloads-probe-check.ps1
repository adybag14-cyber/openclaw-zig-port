param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
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
if ($outputText -match '(?m)^BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Health-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

$firstCode = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_CODE'
$firstAck = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_ACK'
$prevLastSeq = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_PREV_LAST_SEQ'
$prevLastCode = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_PREV_LAST_CODE'
$prevLastAck = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_PREV_LAST_ACK'
$lastCode = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_CODE'
$lastAck = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_ACK'
if ($firstCode -ne 103 -or $firstAck -ne 3 -or $prevLastSeq -ne 70 -or $prevLastCode -ne 134 -or $prevLastAck -ne 34 -or $lastCode -ne 200 -or $lastAck -ne 35) {
    throw "Unexpected overflow payloads. firstCode=$firstCode firstAck=$firstAck prevLastSeq=$prevLastSeq prevLastCode=$prevLastCode prevLastAck=$prevLastAck lastCode=$lastCode lastAck=$lastAck"
}

Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_OVERFLOW_PAYLOADS_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
Write-Output "FIRST_CODE=$firstCode"
Write-Output "FIRST_ACK=$firstAck"
Write-Output "PREV_LAST_SEQ=$prevLastSeq"
Write-Output "PREV_LAST_CODE=$prevLastCode"
Write-Output "PREV_LAST_ACK=$prevLastAck"
Write-Output "LAST_CODE=$lastCode"
Write-Output "LAST_ACK=$lastAck"
