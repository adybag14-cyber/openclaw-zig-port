param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1286
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-descriptor-bootdiag-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-mode-boot-phase-setter-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-mode-boot-phase-setter-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-mode-boot-phase-setter-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-mode-boot-phase-setter-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-mode-boot-phase-setter-probe.qemu.stderr.log"

$setModeOpcode = 4
$setBootPhaseOpcode = 16
$invalidMode = 77
$invalidBootPhase = 99

$modeRunning = 1
$modePanicked = 255
$bootPhaseInit = 1
$bootPhaseRuntime = 2
$modeReasonCommand = 1
$bootReasonCommand = 1

$statusModeOffset = 6
$statusTicksOffset = 8
$statusLastHealthCodeOffset = 16
$statusPanicCountOffset = 24
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$bootDiagPhaseOffset = 6
$bootDiagPhaseChangesOffset = 40

$eventStride = 24
$eventSeqOffset = 0
$eventPrevOffset = 4
$eventNewOffset = 5
$eventReasonOffset = 6

function Resolve-QemuExecutable {
    foreach ($name in @("qemu-system-x86_64", "qemu-system-x86_64.exe", "C:\Program Files\qemu\qemu-system-x86_64.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

function Resolve-GdbExecutable {
    foreach ($name in @("gdb", "gdb.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
    }
    return $null
}

function Resolve-NmExecutable {
    foreach ($name in @("llvm-nm", "llvm-nm.exe", "nm", "nm.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\llvm-nm.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

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
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Mode/boot-phase setter prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) { throw "Prerequisite script not found: $prerequisiteScript" }
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

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MODE_BOOT_PHASE_SETTER_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MODE_BOOT_PHASE_SETTER_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MODE_BOOT_PHASE_SETTER_PROBE=skipped"
    exit 0
}

if (-not (Test-Path $artifact)) {
    Invoke-DescriptorArtifactBuildIfNeeded
} elseif (-not $SkipBuild) {
    Invoke-DescriptorArtifactBuildIfNeeded
}

if (-not (Test-Path $artifact)) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_MODE_BOOT_PHASE_SETTER_PROBE=skipped"
    exit 0
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) {
    throw "Failed to resolve symbol table from $artifact using $nm"
}

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
$bootDiagAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_diagnostics$' -SymbolName "baremetal_main.boot_diagnostics"
$modeHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.mode_history$' -SymbolName "baremetal_main.mode_history"
$modeHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.mode_history_count$' -SymbolName "baremetal_main.mode_history_count"
$modeHistoryHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.mode_history_head$' -SymbolName "baremetal_main.mode_history_head"
$modeHistoryOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.mode_history_overflow$' -SymbolName "baremetal_main.mode_history_overflow"
$modeHistorySeqAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.mode_history_seq$' -SymbolName "baremetal_main.mode_history_seq"
$bootHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_phase_history$' -SymbolName "baremetal_main.boot_phase_history"
$bootHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_phase_history_count$' -SymbolName "baremetal_main.boot_phase_history_count"
$bootHistoryHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_phase_history_head$' -SymbolName "baremetal_main.boot_phase_history_head"
$bootHistoryOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_phase_history_overflow$' -SymbolName "baremetal_main.boot_phase_history_overflow"
$bootHistorySeqAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_phase_history_seq$' -SymbolName "baremetal_main.boot_phase_history_seq"

$artifactForGdb = $artifact.Replace('\', '/')
if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $mode_noop_history_len = 0
set $boot_noop_history_len = 0
set $boot_invalid_result = 0
set $boot_invalid_phase = 0
set $boot_invalid_history_len = 0
set $mode_invalid_result = 0
set $mode_invalid_mode = 0
set $mode_invalid_history_len = 0
file __ARTIFACT__
handle SIGQUIT nostop noprint pass
target remote :__GDBPORT__
break *0x__START__
commands
silent
printf "HIT_START\n"
continue
end
break *0x__SPINPAUSE__
commands
silent
if $stage == 0
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 0
    set *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) = __MODE_RUNNING__
    set *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__) = 0
    set *(unsigned short*)(0x__STATUS__+__STATUS_HEALTH_OFFSET__) = 200
    set *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__) = 0
    set *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) = 0
    set *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) = 0
    set *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) = 0
    set *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) = __BOOT_PHASE_RUNTIME__
    set *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_CHANGES_OFFSET__) = 0
    set *(unsigned int*)0x__MODE_HISTORY_COUNT__ = 0
    set *(unsigned int*)0x__MODE_HISTORY_HEAD__ = 0
    set *(unsigned int*)0x__MODE_HISTORY_OVERFLOW__ = 0
    set *(unsigned int*)0x__MODE_HISTORY_SEQ__ = 0
    set *(unsigned int*)0x__BOOT_HISTORY_COUNT__ = 0
    set *(unsigned int*)0x__BOOT_HISTORY_HEAD__ = 0
    set *(unsigned int*)0x__BOOT_HISTORY_OVERFLOW__ = 0
    set *(unsigned int*)0x__BOOT_HISTORY_SEQ__ = 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_MODE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 1
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __MODE_RUNNING__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 1
  end
  continue
end
if $stage == 1
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 1 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_RUNNING__ && *(unsigned int*)0x__MODE_HISTORY_COUNT__ == 0 && *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__) == 0 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_RUNTIME__ && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 0
    set $mode_noop_history_len = *(unsigned int*)0x__MODE_HISTORY_COUNT__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_BOOT_PHASE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 2
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __BOOT_PHASE_RUNTIME__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 2 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_RUNTIME__ && *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_CHANGES_OFFSET__) == 0 && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 0
    set $boot_noop_history_len = *(unsigned int*)0x__BOOT_HISTORY_COUNT__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_BOOT_PHASE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 3
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __BOOT_PHASE_INIT__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 3 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_INIT__ && *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_CHANGES_OFFSET__) == 1 && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_BOOT_PHASE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 4
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __BOOT_PHASE_INIT__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 4 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_INIT__ && *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_CHANGES_OFFSET__) == 1 && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_BOOT_PHASE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 5
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __INVALID_BOOT_PHASE__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 5 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == -22 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_INIT__ && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 1
    set $boot_invalid_result = *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    set $boot_invalid_phase = *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__)
    set $boot_invalid_history_len = *(unsigned int*)0x__BOOT_HISTORY_COUNT__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_MODE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 6
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __MODE_PANICKED__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 6 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_PANICKED__ && *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__) == 0 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_INIT__ && *(unsigned int*)0x__MODE_HISTORY_COUNT__ == 1 && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_MODE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 7
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __MODE_RUNNING__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 7 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_RUNNING__ && *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__) == 0 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_INIT__ && *(unsigned int*)0x__MODE_HISTORY_COUNT__ == 2 && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_MODE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 8
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __INVALID_MODE__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 8
  end
  continue
end
if $stage == 8
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 8 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == -22 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_RUNNING__ && *(unsigned int*)0x__MODE_HISTORY_COUNT__ == 2 && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 1
    set $mode_invalid_result = *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    set $mode_invalid_mode = *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    set $mode_invalid_history_len = *(unsigned int*)0x__MODE_HISTORY_COUNT__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_MODE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 9
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __MODE_RUNNING__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 9
  end
  continue
end
if $stage == 9
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 9 && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __SET_MODE_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_RUNNING__ && *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__) == 0 && *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) == __BOOT_PHASE_INIT__ && *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_CHANGES_OFFSET__) == 1 && *(unsigned int*)0x__MODE_HISTORY_COUNT__ == 2 && *(unsigned int*)0x__BOOT_HISTORY_COUNT__ == 1
    printf "HIT_AFTER_MODE_BOOT_PHASE_SETTER_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "STATUS_MODE=%u\n", *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    printf "PANIC_COUNT=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__)
    printf "BOOT_PHASE=%u\n", *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__)
    printf "BOOT_PHASE_CHANGES=%u\n", *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_CHANGES_OFFSET__)
    printf "MODE_NOOP_HISTORY_LEN=%u\n", $mode_noop_history_len
    printf "BOOT_NOOP_HISTORY_LEN=%u\n", $boot_noop_history_len
    printf "BOOT_INVALID_RESULT=%d\n", $boot_invalid_result
    printf "BOOT_INVALID_PHASE=%u\n", $boot_invalid_phase
    printf "BOOT_INVALID_HISTORY_LEN=%u\n", $boot_invalid_history_len
    printf "MODE_INVALID_RESULT=%d\n", $mode_invalid_result
    printf "MODE_INVALID_MODE=%u\n", $mode_invalid_mode
    printf "MODE_INVALID_HISTORY_LEN=%u\n", $mode_invalid_history_len
    printf "MODE_HISTORY_LEN=%u\n", *(unsigned int*)0x__MODE_HISTORY_COUNT__
    printf "MODE0_SEQ=%u\n", *(unsigned int*)(0x__MODE_HISTORY__+__EVENT_SEQ_OFFSET__)
    printf "MODE0_PREV=%u\n", *(unsigned char*)(0x__MODE_HISTORY__+__EVENT_PREV_OFFSET__)
    printf "MODE0_NEW=%u\n", *(unsigned char*)(0x__MODE_HISTORY__+__EVENT_NEW_OFFSET__)
    printf "MODE0_REASON=%u\n", *(unsigned char*)(0x__MODE_HISTORY__+__EVENT_REASON_OFFSET__)
    printf "MODE1_SEQ=%u\n", *(unsigned int*)(0x__MODE_HISTORY__+__EVENT_STRIDE__+__EVENT_SEQ_OFFSET__)
    printf "MODE1_PREV=%u\n", *(unsigned char*)(0x__MODE_HISTORY__+__EVENT_STRIDE__+__EVENT_PREV_OFFSET__)
    printf "MODE1_NEW=%u\n", *(unsigned char*)(0x__MODE_HISTORY__+__EVENT_STRIDE__+__EVENT_NEW_OFFSET__)
    printf "MODE1_REASON=%u\n", *(unsigned char*)(0x__MODE_HISTORY__+__EVENT_STRIDE__+__EVENT_REASON_OFFSET__)
    printf "BOOT_HISTORY_LEN=%u\n", *(unsigned int*)0x__BOOT_HISTORY_COUNT__
    printf "BOOT0_SEQ=%u\n", *(unsigned int*)(0x__BOOT_HISTORY__+__EVENT_SEQ_OFFSET__)
    printf "BOOT0_PREV=%u\n", *(unsigned char*)(0x__BOOT_HISTORY__+__EVENT_PREV_OFFSET__)
    printf "BOOT0_NEW=%u\n", *(unsigned char*)(0x__BOOT_HISTORY__+__EVENT_NEW_OFFSET__)
    printf "BOOT0_REASON=%u\n", *(unsigned char*)(0x__BOOT_HISTORY__+__EVENT_REASON_OFFSET__)
    detach
    quit
  end
  continue
end
continue
end
continue
'@

$gdbContent = $gdbTemplate.
    Replace('__ARTIFACT__', $artifactForGdb).
    Replace('__GDBPORT__', [string]$GdbPort).
    Replace('__START__', $startAddress).
    Replace('__SPINPAUSE__', $spinPauseAddress).
    Replace('__STATUS__', $statusAddress).
    Replace('__STATUS_MODE_OFFSET__', [string]$statusModeOffset).
    Replace('__STATUS_TICKS_OFFSET__', [string]$statusTicksOffset).
    Replace('__STATUS_HEALTH_OFFSET__', [string]$statusLastHealthCodeOffset).
    Replace('__STATUS_PANIC_OFFSET__', [string]$statusPanicCountOffset).
    Replace('__STATUS_ACK_OFFSET__', [string]$statusCommandSeqAckOffset).
    Replace('__STATUS_LAST_OPCODE_OFFSET__', [string]$statusLastCommandOpcodeOffset).
    Replace('__STATUS_LAST_RESULT_OFFSET__', [string]$statusLastCommandResultOffset).
    Replace('__COMMAND_MAILBOX__', $commandMailboxAddress).
    Replace('__COMMAND_OPCODE_OFFSET__', [string]$commandOpcodeOffset).
    Replace('__COMMAND_SEQ_OFFSET__', [string]$commandSeqOffset).
    Replace('__COMMAND_ARG0_OFFSET__', [string]$commandArg0Offset).
    Replace('__COMMAND_ARG1_OFFSET__', [string]$commandArg1Offset).
    Replace('__BOOTDIAG__', $bootDiagAddress).
    Replace('__BOOTDIAG_PHASE_OFFSET__', [string]$bootDiagPhaseOffset).
    Replace('__BOOTDIAG_PHASE_CHANGES_OFFSET__', [string]$bootDiagPhaseChangesOffset).
    Replace('__MODE_HISTORY__', $modeHistoryAddress).
    Replace('__MODE_HISTORY_COUNT__', $modeHistoryCountAddress).
    Replace('__MODE_HISTORY_HEAD__', $modeHistoryHeadAddress).
    Replace('__MODE_HISTORY_OVERFLOW__', $modeHistoryOverflowAddress).
    Replace('__MODE_HISTORY_SEQ__', $modeHistorySeqAddress).
    Replace('__BOOT_HISTORY__', $bootHistoryAddress).
    Replace('__BOOT_HISTORY_COUNT__', $bootHistoryCountAddress).
    Replace('__BOOT_HISTORY_HEAD__', $bootHistoryHeadAddress).
    Replace('__BOOT_HISTORY_OVERFLOW__', $bootHistoryOverflowAddress).
    Replace('__BOOT_HISTORY_SEQ__', $bootHistorySeqAddress).
    Replace('__SET_BOOT_PHASE_OPCODE__', [string]$setBootPhaseOpcode).
    Replace('__SET_MODE_OPCODE__', [string]$setModeOpcode).
    Replace('__INVALID_BOOT_PHASE__', [string]$invalidBootPhase).
    Replace('__INVALID_MODE__', [string]$invalidMode).
    Replace('__MODE_RUNNING__', [string]$modeRunning).
    Replace('__MODE_PANICKED__', [string]$modePanicked).
    Replace('__BOOT_PHASE_INIT__', [string]$bootPhaseInit).
    Replace('__BOOT_PHASE_RUNTIME__', [string]$bootPhaseRuntime).
    Replace('__EVENT_STRIDE__', [string]$eventStride).
    Replace('__EVENT_SEQ_OFFSET__', [string]$eventSeqOffset).
    Replace('__EVENT_PREV_OFFSET__', [string]$eventPrevOffset).
    Replace('__EVENT_NEW_OFFSET__', [string]$eventNewOffset).
    Replace('__EVENT_REASON_OFFSET__', [string]$eventReasonOffset)

Set-Content -Path $gdbScript -Value $gdbContent -Encoding Ascii -NoNewline

$qemuArgs = @(
    "-accel", "tcg",
    "-machine", "q35",
    "-cpu", "max",
    "-nographic",
    "-monitor", "none",
    "-serial", "none",
    "-display", "none",
    "-S",
    "-gdb", "tcp::$GdbPort",
    "-kernel", $artifact
)

$qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -PassThru
try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        if ($qemuProcess.HasExited) {
            $stderrText = if (Test-Path $qemuStderr) { Get-Content $qemuStderr -Raw } else { "" }
            $stdoutText = if (Test-Path $qemuStdout) { Get-Content $qemuStdout -Raw } else { "" }
            throw "QEMU exited before GDB completed. stdout: $stdoutText stderr: $stderrText"
        }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect('127.0.0.1', $GdbPort, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(100)) {
                $tcp.EndConnect($async)
                $tcp.Close()
                break
            }
            $tcp.Close()
        } catch {
        }
    } while ((Get-Date) -lt $deadline)

    if ((Get-Date) -ge $deadline) {
        throw "Timed out waiting for QEMU GDB server on port $GdbPort"
    }

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("--quiet", "--batch", "-x", $gdbScript) -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr -PassThru
    if (-not $gdbProcess.WaitForExit($TimeoutSeconds * 1000)) {
        try { $gdbProcess.Kill() } catch {}
        throw "Timed out waiting for GDB mode/boot-phase setter probe"
    }

    $gdbOutput = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
    $gdbError = if (Test-Path $gdbStderr) { Get-Content $gdbStderr -Raw } else { "" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProcess.ExitCode)) { 0 } else { [int]$gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        throw "GDB mode/boot-phase setter probe failed with exit code $gdbExitCode. stdout: $gdbOutput stderr: $gdbError"
    }

    foreach ($requiredMarker in @("HIT_START", "HIT_AFTER_MODE_BOOT_PHASE_SETTER_PROBE")) {
        if ($gdbOutput -notmatch [regex]::Escape($requiredMarker)) {
            throw "Missing expected marker '$requiredMarker' in GDB output. stdout: $gdbOutput stderr: $gdbError"
        }
    }

    $expectations = @{
        "ACK" = 9
        "LAST_OPCODE" = $setModeOpcode
        "LAST_RESULT" = 0
        "STATUS_MODE" = $modeRunning
        "PANIC_COUNT" = 0
        "BOOT_PHASE" = $bootPhaseInit
        "BOOT_PHASE_CHANGES" = 1
        "MODE_NOOP_HISTORY_LEN" = 0
        "BOOT_NOOP_HISTORY_LEN" = 0
        "BOOT_INVALID_RESULT" = -22
        "BOOT_INVALID_PHASE" = $bootPhaseInit
        "BOOT_INVALID_HISTORY_LEN" = 1
        "MODE_INVALID_RESULT" = -22
        "MODE_INVALID_MODE" = $modeRunning
        "MODE_INVALID_HISTORY_LEN" = 2
        "MODE_HISTORY_LEN" = 2
        "MODE0_SEQ" = 1
        "MODE0_PREV" = $modeRunning
        "MODE0_NEW" = $modePanicked
        "MODE0_REASON" = $modeReasonCommand
        "MODE1_SEQ" = 2
        "MODE1_PREV" = $modePanicked
        "MODE1_NEW" = $modeRunning
        "MODE1_REASON" = $modeReasonCommand
        "BOOT_HISTORY_LEN" = 1
        "BOOT0_SEQ" = 1
        "BOOT0_PREV" = $bootPhaseRuntime
        "BOOT0_NEW" = $bootPhaseInit
        "BOOT0_REASON" = $bootReasonCommand
    }

    foreach ($name in $expectations.Keys) {
        $actual = Extract-IntValue -Text $gdbOutput -Name $name
        if ($null -eq $actual) {
            throw "Missing expected field '$name' in probe output. stdout: $gdbOutput stderr: $gdbError"
        }
        if ($actual -ne [int64]$expectations[$name]) {
            throw "Unexpected value for $name. Expected $($expectations[$name]), got $actual. stdout: $gdbOutput stderr: $gdbError"
        }
    }

    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    if ($null -eq $ticks) {
        throw "Missing TICKS in probe output. stdout: $gdbOutput stderr: $gdbError"
    }
    if ($ticks -lt 9) {
        throw "Unexpected TICKS value. Expected at least 9, got $ticks. stdout: $gdbOutput stderr: $gdbError"
    }

    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_MODE_BOOT_PHASE_SETTER_PROBE=pass"
    $gdbOutput.TrimEnd()
} finally {
    if ($null -ne $qemuProcess -and -not $qemuProcess.HasExited) {
        try { $qemuProcess.Kill() } catch {}
        try { $qemuProcess.WaitForExit() } catch {}
    }
}
