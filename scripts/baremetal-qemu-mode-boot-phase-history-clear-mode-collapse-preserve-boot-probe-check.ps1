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
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_MODE_COLLAPSE_PRESERVE_BOOT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_MODE_COLLAPSE_PRESERVE_BOOT_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    throw "Mode/boot-phase history clear prerequisite probe failed with exit code $exitCode"
}

$expected = [ordered]@{
    'POST_CLEAR_MODE_LEN' = 0
    'POST_CLEAR_MODE_HEAD' = 0
    'POST_CLEAR_MODE_OVERFLOW' = 0
    'POST_CLEAR_MODE_SEQ' = 0
    'POST_CLEAR_BOOT_LEN_AFTER_MODE_CLEAR' = 3
}
foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $outputText -Name $entry.Key
    if ($null -eq $actual) { throw "Missing output value for $($entry.Key)" }
    if ($actual -ne $entry.Value) { throw "Unexpected $($entry.Key): got $actual expected $($entry.Value)" }
}

Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_MODE_COLLAPSE_PRESERVE_BOOT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_MODE_COLLAPSE_PRESERVE_BOOT_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
foreach ($entry in $expected.GetEnumerator()) { Write-Output ("{0}={1}" -f $entry.Key, $entry.Value) }
