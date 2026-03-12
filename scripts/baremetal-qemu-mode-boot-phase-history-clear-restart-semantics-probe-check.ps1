param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$invoke = @{ TimeoutSeconds = $TimeoutSeconds }
if ($GdbPort -gt 0) { $invoke.GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
$output | Write-Output
if ($outputText -match '(?m)^BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_RESTART_SEMANTICS_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_RESTART_SEMANTICS_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    throw "Mode/boot-phase history clear prerequisite probe failed with exit code $exitCode"
}

$expected = [ordered]@{
    'RESET_BOOT0_SEQ' = 1
    'RESET_BOOT0_PREV' = 2
    'RESET_BOOT0_NEW' = 1
    'RESET_BOOT0_REASON' = 1
    'ACK' = 7
    'LAST_OPCODE' = 4
    'LAST_RESULT' = 0
    'RESET_MODE_LEN' = 2
    'RESET_MODE_HEAD' = 2
    'RESET_MODE_OVERFLOW' = 0
    'RESET_MODE_SEQ' = 2
    'RESET_MODE0_SEQ' = 1
    'RESET_MODE0_PREV' = 1
    'RESET_MODE0_NEW' = 0
    'RESET_MODE0_REASON' = 1
    'RESET_MODE1_SEQ' = 2
    'RESET_MODE1_PREV' = 0
    'RESET_MODE1_NEW' = 1
    'RESET_MODE1_REASON' = 3
    'RESET_BOOT_LEN' = 2
    'RESET_BOOT_HEAD' = 2
    'RESET_BOOT_OVERFLOW' = 0
    'RESET_BOOT_SEQ' = 2
    'RESET_BOOT1_SEQ' = 2
    'RESET_BOOT1_PREV' = 1
    'RESET_BOOT1_NEW' = 2
    'RESET_BOOT1_REASON' = 2
}
foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $outputText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}
$ticks = Extract-IntValue -Text $outputText -Name 'TICKS'
if ($null -eq $ticks) { throw 'Missing output value for TICKS' }
if ($ticks -lt 7) { throw "Unexpected TICKS: got $ticks expected at least 7" }

Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_RESTART_SEMANTICS_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_RESTART_SEMANTICS_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
foreach ($entry in $expected.GetEnumerator()) { Write-Output ("{0}={1}" -f $entry.Key, $entry.Value) }
Write-Output ("TICKS={0}" -f $ticks)
