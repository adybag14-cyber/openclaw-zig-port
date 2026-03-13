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
    Write-Output 'BAREMETAL_QEMU_PS2_INPUT_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_PS2_INPUT_BASELINE_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) { throw "Underlying PS/2 probe failed with exit code $probeExitCode" }

$mailboxAck = Extract-IntValue -Text $probeText -Name 'MAILBOX_ACK'
$mailboxLastOpcode = Extract-IntValue -Text $probeText -Name 'MAILBOX_LAST_OPCODE'
$mailboxLastResult = Extract-IntValue -Text $probeText -Name 'MAILBOX_LAST_RESULT'
$keyboardConnected = Extract-IntValue -Text $probeText -Name 'KEYBOARD_CONNECTED'
$mouseConnected = Extract-IntValue -Text $probeText -Name 'MOUSE_CONNECTED'
if ($null -in @($mailboxAck, $mailboxLastOpcode, $mailboxLastResult, $keyboardConnected, $mouseConnected)) {
    throw 'Missing baseline fields in PS/2 probe output.'
}
if ($mailboxAck -ne 3) { throw "Expected MAILBOX_ACK=3, got $mailboxAck" }
if ($mailboxLastOpcode -ne 7) { throw "Expected MAILBOX_LAST_OPCODE=7, got $mailboxLastOpcode" }
if ($mailboxLastResult -ne 0) { throw "Expected MAILBOX_LAST_RESULT=0, got $mailboxLastResult" }
if ($keyboardConnected -ne 1) { throw "Expected KEYBOARD_CONNECTED=1, got $keyboardConnected" }
if ($mouseConnected -ne 1) { throw "Expected MOUSE_CONNECTED=1, got $mouseConnected" }

Write-Output 'BAREMETAL_QEMU_PS2_INPUT_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_PS2_INPUT_BASELINE_PROBE_SOURCE=baremetal-qemu-ps2-input-probe-check.ps1'
Write-Output "MAILBOX_ACK=$mailboxAck"
Write-Output "MAILBOX_LAST_OPCODE=$mailboxLastOpcode"
Write-Output "MAILBOX_LAST_RESULT=$mailboxLastResult"
Write-Output "KEYBOARD_CONNECTED=$keyboardConnected"
Write-Output "MOUSE_CONNECTED=$mouseConnected"
