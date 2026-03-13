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
    Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_MODIFIER_QUEUE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_MODIFIER_QUEUE_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) { throw "Underlying PS/2 probe failed with exit code $probeExitCode" }

$modifiers = Extract-IntValue -Text $probeText -Name 'KEYBOARD_MODIFIERS'
$queueLen = Extract-IntValue -Text $probeText -Name 'KEYBOARD_QUEUE_LEN'
$eventCount = Extract-IntValue -Text $probeText -Name 'KEYBOARD_EVENT_COUNT'
$lastScancode = Extract-IntValue -Text $probeText -Name 'KEYBOARD_LAST_SCANCODE'
$lastKeycode = Extract-IntValue -Text $probeText -Name 'KEYBOARD_LAST_KEYCODE'
if ($null -in @($modifiers, $queueLen, $eventCount, $lastScancode, $lastKeycode)) {
    throw 'Missing keyboard modifier/queue fields in PS/2 probe output.'
}
if ($modifiers -ne 1) { throw "Expected KEYBOARD_MODIFIERS=1, got $modifiers" }
if ($queueLen -ne 2) { throw "Expected KEYBOARD_QUEUE_LEN=2, got $queueLen" }
if ($eventCount -ne 2) { throw "Expected KEYBOARD_EVENT_COUNT=2, got $eventCount" }
if ($lastScancode -ne 30) { throw "Expected KEYBOARD_LAST_SCANCODE=30, got $lastScancode" }
if ($lastKeycode -ne 65) { throw "Expected KEYBOARD_LAST_KEYCODE=65, got $lastKeycode" }

Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_MODIFIER_QUEUE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_PS2_KEYBOARD_MODIFIER_QUEUE_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
Write-Output "KEYBOARD_MODIFIERS=$modifiers"
Write-Output "KEYBOARD_QUEUE_LEN=$queueLen"
Write-Output "KEYBOARD_EVENT_COUNT=$eventCount"
Write-Output "KEYBOARD_LAST_SCANCODE=$lastScancode"
Write-Output "KEYBOARD_LAST_KEYCODE=$lastKeycode"
