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
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PRE_SEMANTICS_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PRE_SEMANTICS_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    throw "Mode/boot-phase history clear prerequisite probe failed with exit code $exitCode"
}

$expected = [ordered]@{
    'PRE_MODE_LEN' = 3
    'PRE_MODE_LAST_SEQ' = 3
    'PRE_MODE2_PREV' = 1
    'PRE_MODE2_NEW' = 255
    'PRE_MODE2_REASON' = 2
    'PRE_BOOT_LEN' = 3
    'PRE_BOOT_LAST_SEQ' = 3
    'PRE_BOOT2_PREV' = 2
    'PRE_BOOT2_NEW' = 255
    'PRE_BOOT2_REASON' = 3
}
foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $outputText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}

Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PRE_SEMANTICS_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PRE_SEMANTICS_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
foreach ($entry in $expected.GetEnumerator()) { Write-Output ("{0}={1}" -f $entry.Key, $entry.Value) }
