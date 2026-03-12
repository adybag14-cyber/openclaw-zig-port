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
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_CLEAR_EVENT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_CLEAR_EVENT_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Health-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

$clearLen = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_LEN'
$clearFirstSeq = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_SEQ'
$clearFirstCode = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_CODE'
$clearFirstMode = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_MODE'
$clearFirstTick = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_TICK'
$clearFirstAck = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_ACK'
if ($clearLen -ne 1 -or $clearFirstSeq -ne 1 -or $clearFirstCode -ne 200 -or $clearFirstMode -ne 1 -or $clearFirstTick -ne 6 -or $clearFirstAck -ne 6) {
    throw "Unexpected clear-event payload. clearLen=$clearLen clearFirstSeq=$clearFirstSeq clearFirstCode=$clearFirstCode clearFirstMode=$clearFirstMode clearFirstTick=$clearFirstTick clearFirstAck=$clearFirstAck"
}

Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_CLEAR_EVENT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_CLEAR_EVENT_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
Write-Output "CLEAR_LEN=$clearLen"
Write-Output "CLEAR_FIRST_SEQ=$clearFirstSeq"
Write-Output "CLEAR_FIRST_CODE=$clearFirstCode"
Write-Output "CLEAR_FIRST_MODE=$clearFirstMode"
Write-Output "CLEAR_FIRST_TICK=$clearFirstTick"
Write-Output "CLEAR_FIRST_ACK=$clearFirstAck"
