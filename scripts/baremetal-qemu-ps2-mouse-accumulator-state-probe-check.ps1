param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-ps2-input-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_PS2_INPUT_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_ACCUMULATOR_STATE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_ACCUMULATOR_STATE_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) { throw "Underlying PS/2 probe failed with exit code $probeExitCode" }

$connected = Extract-IntValue -Text $probeText -Name 'MOUSE_CONNECTED'
$queueLen = Extract-IntValue -Text $probeText -Name 'MOUSE_QUEUE_LEN'
$packetCount = Extract-IntValue -Text $probeText -Name 'MOUSE_PACKET_COUNT'
$lastButtons = Extract-IntValue -Text $probeText -Name 'MOUSE_LAST_BUTTONS'
$accumX = Extract-IntValue -Text $probeText -Name 'MOUSE_ACCUM_X'
$accumY = Extract-IntValue -Text $probeText -Name 'MOUSE_ACCUM_Y'
$lastDx = Extract-IntValue -Text $probeText -Name 'MOUSE_LAST_DX'
$lastDy = Extract-IntValue -Text $probeText -Name 'MOUSE_LAST_DY'
if ($null -in @($connected, $queueLen, $packetCount, $lastButtons, $accumX, $accumY, $lastDx, $lastDy)) {
    throw 'Missing mouse accumulator/state fields in PS/2 probe output.'
}
if ($connected -ne 1) { throw "Expected MOUSE_CONNECTED=1, got $connected" }
if ($queueLen -ne 1) { throw "Expected MOUSE_QUEUE_LEN=1, got $queueLen" }
if ($packetCount -ne 1) { throw "Expected MOUSE_PACKET_COUNT=1, got $packetCount" }
if ($lastButtons -ne 5) { throw "Expected MOUSE_LAST_BUTTONS=5, got $lastButtons" }
if ($accumX -ne 6) { throw "Expected MOUSE_ACCUM_X=6, got $accumX" }
if ($accumY -ne -3) { throw "Expected MOUSE_ACCUM_Y=-3, got $accumY" }
if ($lastDx -ne 6) { throw "Expected MOUSE_LAST_DX=6, got $lastDx" }
if ($lastDy -ne -3) { throw "Expected MOUSE_LAST_DY=-3, got $lastDy" }

Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_ACCUMULATOR_STATE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_ACCUMULATOR_STATE_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
Write-Output "MOUSE_CONNECTED=$connected"
Write-Output "MOUSE_QUEUE_LEN=$queueLen"
Write-Output "MOUSE_PACKET_COUNT=$packetCount"
Write-Output "MOUSE_LAST_BUTTONS=$lastButtons"
Write-Output "MOUSE_ACCUM_X=$accumX"
Write-Output "MOUSE_ACCUM_Y=$accumY"
Write-Output "MOUSE_LAST_DX=$lastDx"
Write-Output "MOUSE_LAST_DY=$lastDy"
