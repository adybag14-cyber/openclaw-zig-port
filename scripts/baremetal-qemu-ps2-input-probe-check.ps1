param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1293
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-descriptor-bootdiag-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$triggerInterruptOpcode = 7
$keyboardVector = 33
$mouseVector = 44

$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$keyboardConnectedOffset = 6
$keyboardModifiersOffset = 7
$keyboardQueueLenOffset = 8
$keyboardEventCountOffset = 12
$keyboardLastScancodeOffset = 24
$keyboardLastKeycodeOffset = 28
$keyboardLastTickOffset = 32

$keyboardEventStride = 32
$keyboardEventSeqOffset = 0
$keyboardEventScancodeOffset = 4
$keyboardEventPressedOffset = 5
$keyboardEventModifiersOffset = 6
$keyboardEventKeycodeOffset = 8
$keyboardEventTickOffset = 16
$keyboardEventInterruptSeqOffset = 24

$mouseConnectedOffset = 6
$mouseQueueLenOffset = 8
$mousePacketCountOffset = 12
$mouseLastButtonsOffset = 16
$mouseAccumXOffset = 20
$mouseAccumYOffset = 24
$mouseLastDxOffset = 28
$mouseLastDyOffset = 30
$mouseLastTickOffset = 32

$mousePacketStride = 32
$mousePacketSeqOffset = 0
$mousePacketButtonsOffset = 4
$mousePacketDxOffset = 6
$mousePacketDyOffset = 8
$mousePacketTickOffset = 16
$mousePacketInterruptSeqOffset = 24

$pendingMouseButtonsOffset = 0
$pendingMouseDxOffset = 2
$pendingMouseDyOffset = 4

function Resolve-PreferredExecutable {
    param([string[]] $Candidates)
    foreach ($name in $Candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

function Resolve-QemuExecutable { return Resolve-PreferredExecutable @("qemu-system-x86_64", "qemu-system-x86_64.exe", "C:\Program Files\qemu\qemu-system-x86_64.exe") }
function Resolve-GdbExecutable { return Resolve-PreferredExecutable @("gdb", "gdb.exe") }
function Resolve-NmExecutable { return Resolve-PreferredExecutable @("llvm-nm", "llvm-nm.exe", "nm", "nm.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\llvm-nm.exe") }

function Resolve-SymbolAddress {
    param([string[]] $SymbolLines, [string] $Pattern, [string] $SymbolName)
    $line = $SymbolLines | Where-Object { $_ -match $Pattern } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { throw "Failed to resolve symbol address for $SymbolName" }
    $parts = ($line.Trim() -split '\s+')
    if ($parts.Count -lt 3) { throw "Unexpected symbol line while resolving ${SymbolName}: $line" }
    return $parts[0]
}

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Invoke-DescriptorArtifactBuildIfNeeded {
    if ($SkipBuild -and -not (Test-Path $artifact)) {
        throw "PS/2 prerequisite artifact not found at $artifact and -SkipBuild was supplied."
    }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) {
        throw "Prerequisite script not found: $prerequisiteScript"
    }
    $prereqOutput = & $prerequisiteScript 2>&1
    $prereqExitCode = $LASTEXITCODE
    if ($prereqExitCode -ne 0) {
        if ($null -ne $prereqOutput) { $prereqOutput | Write-Output }
        throw "Descriptor bootdiag prerequisite failed with exit code $prereqExitCode"
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable

if ($null -eq $qemu -or $null -eq $gdb -or $null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=$([bool]($null -ne $qemu))"
    Write-Output "BAREMETAL_GDB_AVAILABLE=$([bool]($null -ne $gdb))"
    Write-Output "BAREMETAL_NM_AVAILABLE=$([bool]($null -ne $nm))"
    Write-Output "BAREMETAL_QEMU_PS2_INPUT_PROBE=skipped"
    return
}

if (-not (Test-Path $artifact)) {
    Invoke-DescriptorArtifactBuildIfNeeded
} elseif (-not $SkipBuild) {
    Invoke-DescriptorArtifactBuildIfNeeded
}

if (-not (Test-Path $artifact)) {
    Write-Output "BAREMETAL_QEMU_PS2_INPUT_PROBE=skipped"
    return
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) {
    throw "Failed to resolve symbol table from $artifact using $nm"
}

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
$keyboardStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.keyboard_state$' -SymbolName "baremetal.ps2_input.keyboard_state"
$keyboardEventsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.keyboard_events$' -SymbolName "baremetal.ps2_input.keyboard_events"
$pendingKeyboardAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.pending_keyboard$' -SymbolName "baremetal.ps2_input.pending_keyboard"
$pendingKeyboardHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.pending_keyboard_head$' -SymbolName "baremetal.ps2_input.pending_keyboard_head"
$pendingKeyboardCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.pending_keyboard_count$' -SymbolName "baremetal.ps2_input.pending_keyboard_count"
$mouseStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.mouse_state$' -SymbolName "baremetal.ps2_input.mouse_state"
$mousePacketsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.mouse_packets$' -SymbolName "baremetal.ps2_input.mouse_packets"
$pendingMouseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.pending_mouse$' -SymbolName "baremetal.ps2_input.pending_mouse"
$pendingMouseHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.pending_mouse_head$' -SymbolName "baremetal.ps2_input.pending_mouse_head"
$pendingMouseCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.ps2_input\.pending_mouse_count$' -SymbolName "baremetal.ps2_input.pending_mouse_count"

$artifactForGdb = $artifact.Replace('\', '/')
$gdbScript = Join-Path $releaseDir "qemu-ps2-input-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-ps2-input-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-ps2-input-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-ps2-input-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-ps2-input-probe-$runStamp.qemu.stderr.log"

foreach ($path in @($gdbStdout, $gdbStderr, $qemuStdout, $qemuStderr)) {
    if (Test-Path $path) { Remove-Item -Force $path }
}

@"
set pagination off
set confirm off
set `$stage = 0
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START=1\n"
continue
end
break *0x$spinPauseAddress
commands
silent
if `$stage == 0
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 0
    set *(unsigned int*)0x$pendingKeyboardHeadAddress = 0
    set *(unsigned int*)0x$pendingKeyboardCountAddress = 1
    set *(unsigned char*)0x$pendingKeyboardAddress = 42
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $keyboardVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 1
  end
  continue
end
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned short*)(0x$keyboardStateAddress+$keyboardQueueLenOffset) == 1 && *(unsigned int*)(0x$keyboardStateAddress+$keyboardEventCountOffset) == 1
    set *(unsigned int*)0x$pendingKeyboardHeadAddress = 0
    set *(unsigned int*)0x$pendingKeyboardCountAddress = 1
    set *(unsigned char*)0x$pendingKeyboardAddress = 30
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $keyboardVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned short*)(0x$keyboardStateAddress+$keyboardQueueLenOffset) == 2 && *(unsigned int*)(0x$keyboardStateAddress+$keyboardEventCountOffset) == 2 && *(unsigned short*)(0x$keyboardStateAddress+$keyboardLastKeycodeOffset) == 65
    set *(unsigned int*)0x$pendingMouseHeadAddress = 0
    set *(unsigned int*)0x$pendingMouseCountAddress = 1
    set *(unsigned char*)(0x$pendingMouseAddress+$pendingMouseButtonsOffset) = 5
    set *(short*)(0x$pendingMouseAddress+$pendingMouseDxOffset) = 6
    set *(short*)(0x$pendingMouseAddress+$pendingMouseDyOffset) = -3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $mouseVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3 && *(unsigned short*)(0x$mouseStateAddress+$mouseQueueLenOffset) == 1 && *(unsigned int*)(0x$mouseStateAddress+$mousePacketCountOffset) == 1
    printf "HIT_AFTER_PS2_INPUT=1\n"
    printf "MAILBOX_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "MAILBOX_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "MAILBOX_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "KEYBOARD_CONNECTED=%u\n", *(unsigned char*)(0x$keyboardStateAddress+$keyboardConnectedOffset)
    printf "KEYBOARD_MODIFIERS=%u\n", *(unsigned char*)(0x$keyboardStateAddress+$keyboardModifiersOffset)
    printf "KEYBOARD_QUEUE_LEN=%u\n", *(unsigned short*)(0x$keyboardStateAddress+$keyboardQueueLenOffset)
    printf "KEYBOARD_EVENT_COUNT=%u\n", *(unsigned int*)(0x$keyboardStateAddress+$keyboardEventCountOffset)
    printf "KEYBOARD_LAST_SCANCODE=%u\n", *(unsigned char*)(0x$keyboardStateAddress+$keyboardLastScancodeOffset)
    printf "KEYBOARD_LAST_KEYCODE=%u\n", *(unsigned short*)(0x$keyboardStateAddress+$keyboardLastKeycodeOffset)
    printf "KEYBOARD_LAST_TICK=%llu\n", *(unsigned long long*)(0x$keyboardStateAddress+$keyboardLastTickOffset)
    printf "KEYBOARD_EVENT0_SEQ=%u\n", *(unsigned int*)(0x$keyboardEventsAddress+$keyboardEventSeqOffset)
    printf "KEYBOARD_EVENT0_SCANCODE=%u\n", *(unsigned char*)(0x$keyboardEventsAddress+$keyboardEventScancodeOffset)
    printf "KEYBOARD_EVENT0_PRESSED=%u\n", *(unsigned char*)(0x$keyboardEventsAddress+$keyboardEventPressedOffset)
    printf "KEYBOARD_EVENT0_MODIFIERS=%u\n", *(unsigned char*)(0x$keyboardEventsAddress+$keyboardEventModifiersOffset)
    printf "KEYBOARD_EVENT0_KEYCODE=%u\n", *(unsigned short*)(0x$keyboardEventsAddress+$keyboardEventKeycodeOffset)
    printf "KEYBOARD_EVENT0_TICK=%llu\n", *(unsigned long long*)(0x$keyboardEventsAddress+$keyboardEventTickOffset)
    printf "KEYBOARD_EVENT0_INTERRUPT_SEQ=%u\n", *(unsigned int*)(0x$keyboardEventsAddress+$keyboardEventInterruptSeqOffset)
    printf "KEYBOARD_EVENT1_SEQ=%u\n", *(unsigned int*)(0x$keyboardEventsAddress+$keyboardEventStride+$keyboardEventSeqOffset)
    printf "KEYBOARD_EVENT1_SCANCODE=%u\n", *(unsigned char*)(0x$keyboardEventsAddress+$keyboardEventStride+$keyboardEventScancodeOffset)
    printf "KEYBOARD_EVENT1_PRESSED=%u\n", *(unsigned char*)(0x$keyboardEventsAddress+$keyboardEventStride+$keyboardEventPressedOffset)
    printf "KEYBOARD_EVENT1_MODIFIERS=%u\n", *(unsigned char*)(0x$keyboardEventsAddress+$keyboardEventStride+$keyboardEventModifiersOffset)
    printf "KEYBOARD_EVENT1_KEYCODE=%u\n", *(unsigned short*)(0x$keyboardEventsAddress+$keyboardEventStride+$keyboardEventKeycodeOffset)
    printf "KEYBOARD_EVENT1_TICK=%llu\n", *(unsigned long long*)(0x$keyboardEventsAddress+$keyboardEventStride+$keyboardEventTickOffset)
    printf "KEYBOARD_EVENT1_INTERRUPT_SEQ=%u\n", *(unsigned int*)(0x$keyboardEventsAddress+$keyboardEventStride+$keyboardEventInterruptSeqOffset)
    printf "MOUSE_CONNECTED=%u\n", *(unsigned char*)(0x$mouseStateAddress+$mouseConnectedOffset)
    printf "MOUSE_QUEUE_LEN=%u\n", *(unsigned short*)(0x$mouseStateAddress+$mouseQueueLenOffset)
    printf "MOUSE_PACKET_COUNT=%u\n", *(unsigned int*)(0x$mouseStateAddress+$mousePacketCountOffset)
    printf "MOUSE_LAST_BUTTONS=%u\n", *(unsigned char*)(0x$mouseStateAddress+$mouseLastButtonsOffset)
    printf "MOUSE_ACCUM_X=%d\n", *(int*)(0x$mouseStateAddress+$mouseAccumXOffset)
    printf "MOUSE_ACCUM_Y=%d\n", *(int*)(0x$mouseStateAddress+$mouseAccumYOffset)
    printf "MOUSE_LAST_DX=%d\n", *(short*)(0x$mouseStateAddress+$mouseLastDxOffset)
    printf "MOUSE_LAST_DY=%d\n", *(short*)(0x$mouseStateAddress+$mouseLastDyOffset)
    printf "MOUSE_LAST_TICK=%llu\n", *(unsigned long long*)(0x$mouseStateAddress+$mouseLastTickOffset)
    printf "MOUSE_PACKET0_SEQ=%u\n", *(unsigned int*)(0x$mousePacketsAddress+$mousePacketSeqOffset)
    printf "MOUSE_PACKET0_BUTTONS=%u\n", *(unsigned char*)(0x$mousePacketsAddress+$mousePacketButtonsOffset)
    printf "MOUSE_PACKET0_DX=%d\n", *(short*)(0x$mousePacketsAddress+$mousePacketDxOffset)
    printf "MOUSE_PACKET0_DY=%d\n", *(short*)(0x$mousePacketsAddress+$mousePacketDyOffset)
    printf "MOUSE_PACKET0_TICK=%llu\n", *(unsigned long long*)(0x$mousePacketsAddress+$mousePacketTickOffset)
    printf "MOUSE_PACKET0_INTERRUPT_SEQ=%u\n", *(unsigned int*)(0x$mousePacketsAddress+$mousePacketInterruptSeqOffset)
    detach
    quit
  end
  continue
end
continue
end
continue
"@ | Set-Content -Path $gdbScript -NoNewline

$qemuArgs = @(
    "-kernel", $artifact,
    "-display", "none",
    "-no-reboot",
    "-no-shutdown",
    "-S",
    "-gdb", "tcp::$GdbPort"
)

$qemuProcess = $null
try {
    $qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
    Start-Sleep -Milliseconds 500

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("-q", "-x", $gdbScript) -PassThru -Wait -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr
    $gdbExitCode = $gdbProcess.ExitCode
    $gdbText = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
    if ($gdbExitCode -ne 0) {
        if ($gdbText) { $gdbText | Write-Output }
        throw "GDB probe failed with exit code $gdbExitCode"
    }
    $gdbText | Set-Content -Path $gdbStdout
    $gdbText | Write-Output

    if ($gdbText -notmatch 'HIT_START=1' -or $gdbText -notmatch 'HIT_AFTER_PS2_INPUT=1') {
        throw "Probe did not reach all expected stages."
    }

    $required = @(
        'MAILBOX_ACK','MAILBOX_LAST_OPCODE','MAILBOX_LAST_RESULT',
        'KEYBOARD_CONNECTED','KEYBOARD_MODIFIERS','KEYBOARD_QUEUE_LEN','KEYBOARD_EVENT_COUNT','KEYBOARD_LAST_SCANCODE','KEYBOARD_LAST_KEYCODE',
        'KEYBOARD_EVENT0_SCANCODE','KEYBOARD_EVENT0_KEYCODE','KEYBOARD_EVENT0_INTERRUPT_SEQ',
        'KEYBOARD_EVENT1_SCANCODE','KEYBOARD_EVENT1_KEYCODE','KEYBOARD_EVENT1_INTERRUPT_SEQ',
        'MOUSE_CONNECTED','MOUSE_QUEUE_LEN','MOUSE_PACKET_COUNT','MOUSE_LAST_BUTTONS','MOUSE_ACCUM_X','MOUSE_ACCUM_Y',
        'MOUSE_PACKET0_BUTTONS','MOUSE_PACKET0_DX','MOUSE_PACKET0_DY','MOUSE_PACKET0_INTERRUPT_SEQ'
    )
    foreach ($name in $required) {
        if ($null -eq (Extract-IntValue -Text $gdbText -Name $name)) {
            throw "Probe output missing required value: $name"
        }
    }

    if ((Extract-IntValue -Text $gdbText -Name 'MAILBOX_ACK') -ne 3) { throw "Expected mailbox ack 3" }
    if ((Extract-IntValue -Text $gdbText -Name 'MAILBOX_LAST_OPCODE') -ne $triggerInterruptOpcode) { throw "Expected final opcode $triggerInterruptOpcode" }
    if ((Extract-IntValue -Text $gdbText -Name 'MAILBOX_LAST_RESULT') -ne 0) { throw "Expected final result 0" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_CONNECTED') -ne 1) { throw "Expected keyboard connected state" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_MODIFIERS') -ne 1) { throw "Expected keyboard modifiers 1" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_QUEUE_LEN') -ne 2) { throw "Expected keyboard queue len 2" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_EVENT_COUNT') -ne 2) { throw "Expected keyboard event count 2" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_LAST_SCANCODE') -ne 30) { throw "Expected keyboard last scancode 30" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_LAST_KEYCODE') -ne 65) { throw "Expected keyboard last keycode 65" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_EVENT0_SCANCODE') -ne 42) { throw "Expected first keyboard event scancode 42" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_EVENT0_KEYCODE') -ne 42) { throw "Expected first keyboard event keycode 42" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_EVENT0_INTERRUPT_SEQ') -ne 1) { throw "Expected first keyboard event interrupt seq 1" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_EVENT1_SCANCODE') -ne 30) { throw "Expected second keyboard event scancode 30" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_EVENT1_KEYCODE') -ne 65) { throw "Expected second keyboard event keycode 65" }
    if ((Extract-IntValue -Text $gdbText -Name 'KEYBOARD_EVENT1_INTERRUPT_SEQ') -ne 2) { throw "Expected second keyboard event interrupt seq 2" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_CONNECTED') -ne 1) { throw "Expected mouse connected state" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_QUEUE_LEN') -ne 1) { throw "Expected mouse queue len 1" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_PACKET_COUNT') -ne 1) { throw "Expected mouse packet count 1" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_LAST_BUTTONS') -ne 5) { throw "Expected mouse buttons 5" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_ACCUM_X') -ne 6) { throw "Expected mouse accum x 6" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_ACCUM_Y') -ne -3) { throw "Expected mouse accum y -3" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_PACKET0_BUTTONS') -ne 5) { throw "Expected mouse packet buttons 5" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_PACKET0_DX') -ne 6) { throw "Expected mouse packet dx 6" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_PACKET0_DY') -ne -3) { throw "Expected mouse packet dy -3" }
    if ((Extract-IntValue -Text $gdbText -Name 'MOUSE_PACKET0_INTERRUPT_SEQ') -ne 3) { throw "Expected mouse packet interrupt seq 3" }

    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_PS2_INPUT_PROBE=pass"
} finally {
    if ($null -ne $qemuProcess -and -not $qemuProcess.HasExited) {
        Stop-Process -Id $qemuProcess.Id -Force
        $qemuProcess.WaitForExit()
    }
}
