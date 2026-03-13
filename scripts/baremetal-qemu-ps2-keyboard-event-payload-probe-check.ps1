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
    Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_EVENT_PAYLOAD_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_EVENT_PAYLOAD_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) { throw "Underlying PS/2 probe failed with exit code $probeExitCode" }

$event0Scancode = Extract-IntValue -Text $probeText -Name 'KEYBOARD_EVENT0_SCANCODE'
$event0Keycode = Extract-IntValue -Text $probeText -Name 'KEYBOARD_EVENT0_KEYCODE'
$event0InterruptSeq = Extract-IntValue -Text $probeText -Name 'KEYBOARD_EVENT0_INTERRUPT_SEQ'
$event1Scancode = Extract-IntValue -Text $probeText -Name 'KEYBOARD_EVENT1_SCANCODE'
$event1Keycode = Extract-IntValue -Text $probeText -Name 'KEYBOARD_EVENT1_KEYCODE'
$event1InterruptSeq = Extract-IntValue -Text $probeText -Name 'KEYBOARD_EVENT1_INTERRUPT_SEQ'
if ($null -in @($event0Scancode, $event0Keycode, $event0InterruptSeq, $event1Scancode, $event1Keycode, $event1InterruptSeq)) {
    throw 'Missing keyboard payload fields in PS/2 probe output.'
}
if ($event0Scancode -ne 42) { throw "Expected KEYBOARD_EVENT0_SCANCODE=42, got $event0Scancode" }
if ($event0Keycode -ne 42) { throw "Expected KEYBOARD_EVENT0_KEYCODE=42, got $event0Keycode" }
if ($event0InterruptSeq -ne 1) { throw "Expected KEYBOARD_EVENT0_INTERRUPT_SEQ=1, got $event0InterruptSeq" }
if ($event1Scancode -ne 30) { throw "Expected KEYBOARD_EVENT1_SCANCODE=30, got $event1Scancode" }
if ($event1Keycode -ne 65) { throw "Expected KEYBOARD_EVENT1_KEYCODE=65, got $event1Keycode" }
if ($event1InterruptSeq -ne 2) { throw "Expected KEYBOARD_EVENT1_INTERRUPT_SEQ=2, got $event1InterruptSeq" }

Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_EVENT_PAYLOAD_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_EVENT_PAYLOAD_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
Write-Output "KEYBOARD_EVENT0_SCANCODE=$event0Scancode"
Write-Output "KEYBOARD_EVENT0_KEYCODE=$event0Keycode"
Write-Output "KEYBOARD_EVENT0_INTERRUPT_SEQ=$event0InterruptSeq"
Write-Output "KEYBOARD_EVENT1_SCANCODE=$event1Scancode"
Write-Output "KEYBOARD_EVENT1_KEYCODE=$event1Keycode"
Write-Output "KEYBOARD_EVENT1_INTERRUPT_SEQ=$event1InterruptSeq"
