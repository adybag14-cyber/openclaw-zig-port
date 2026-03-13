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
    Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_PACKET_PAYLOAD_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_PACKET_PAYLOAD_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) { throw "Underlying PS/2 probe failed with exit code $probeExitCode" }

$seq = Extract-IntValue -Text $probeText -Name 'MOUSE_PACKET0_SEQ'
$buttons = Extract-IntValue -Text $probeText -Name 'MOUSE_PACKET0_BUTTONS'
$dx = Extract-IntValue -Text $probeText -Name 'MOUSE_PACKET0_DX'
$dy = Extract-IntValue -Text $probeText -Name 'MOUSE_PACKET0_DY'
$tick = Extract-IntValue -Text $probeText -Name 'MOUSE_PACKET0_TICK'
$interruptSeq = Extract-IntValue -Text $probeText -Name 'MOUSE_PACKET0_INTERRUPT_SEQ'
if ($null -in @($seq, $buttons, $dx, $dy, $tick, $interruptSeq)) {
    throw 'Missing mouse packet payload fields in PS/2 probe output.'
}
if ($seq -ne 1) { throw "Expected MOUSE_PACKET0_SEQ=1, got $seq" }
if ($buttons -ne 5) { throw "Expected MOUSE_PACKET0_BUTTONS=5, got $buttons" }
if ($dx -ne 6) { throw "Expected MOUSE_PACKET0_DX=6, got $dx" }
if ($dy -ne -3) { throw "Expected MOUSE_PACKET0_DY=-3, got $dy" }
if ($tick -ne 3) { throw "Expected MOUSE_PACKET0_TICK=3, got $tick" }
if ($interruptSeq -ne 3) { throw "Expected MOUSE_PACKET0_INTERRUPT_SEQ=3, got $interruptSeq" }

Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_PACKET_PAYLOAD_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_PS2_MOUSE_PACKET_PAYLOAD_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
Write-Output "MOUSE_PACKET0_SEQ=$seq"
Write-Output "MOUSE_PACKET0_BUTTONS=$buttons"
Write-Output "MOUSE_PACKET0_DX=$dx"
Write-Output "MOUSE_PACKET0_DY=$dy"
Write-Output "MOUSE_PACKET0_TICK=$tick"
Write-Output "MOUSE_PACKET0_INTERRUPT_SEQ=$interruptSeq"
