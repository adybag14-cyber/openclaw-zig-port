param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1266
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-descriptor-bootdiag-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-bootdiag-history-clear-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-bootdiag-history-clear-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-bootdiag-history-clear-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-bootdiag-history-clear-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-bootdiag-history-clear-probe.qemu.stderr.log"

$setHealthCodeOpcode = 1
$setBootPhaseOpcode = 16
$resetBootDiagnosticsOpcode = 17
$captureStackPointerOpcode = 18
$clearCommandHistoryOpcode = 19
$clearHealthHistoryOpcode = 20

$healthCode = 418
$bootPhaseInit = 1
$bootPhaseRuntime = 2
$modeRunning = 1

$statusModeOffset = 6
$statusTicksOffset = 8
$statusLastHealthCodeOffset = 16
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$bootDiagPhaseOffset = 6
$bootDiagBootSeqOffset = 8
$bootDiagLastCommandSeqOffset = 12
$bootDiagLastCommandTickOffset = 16
$bootDiagLastTickObservedOffset = 24
$bootDiagStackPointerSnapshotOffset = 32
$bootDiagPhaseChangesOffset = 40

$commandHistoryCountOffset = 0
$commandHistoryHeadOffset = 0
$commandHistoryOverflowOffset = 0
$healthHistoryCountOffset = 0
$healthHistoryHeadOffset = 0
$healthHistoryOverflowOffset = 0
$healthHistorySeqOffset = 0

$commandEventSeqOffset = 0
$commandEventOpcodeOffset = 4
$commandEventResultOffset = 6
$commandEventTickOffset = 8
$commandEventArg0Offset = 16
$commandEventArg1Offset = 24
$commandEventStride = 32

$healthEventSeqOffset = 0
$healthEventCodeOffset = 4
$healthEventModeOffset = 6
$healthEventTickOffset = 8
$healthEventAckOffset = 16
$healthEventStride = 24

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
    if ($SkipBuild -and -not (Test-Path $artifact)) {
        throw "Descriptor prerequisite artifact not found at $artifact and -SkipBuild was supplied."
    }
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
    Write-Output "BAREMETAL_QEMU_BOOTDIAG_HISTORY_CLEAR_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_BOOTDIAG_HISTORY_CLEAR_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_BOOTDIAG_HISTORY_CLEAR_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_BOOTDIAG_HISTORY_CLEAR_PROBE=skipped"
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
$commandHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history$' -SymbolName "baremetal_main.command_history"
$commandHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history_count$' -SymbolName "baremetal_main.command_history_count"
$commandHistoryHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history_head$' -SymbolName "baremetal_main.command_history_head"
$commandHistoryOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history_overflow$' -SymbolName "baremetal_main.command_history_overflow"
$healthHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history$' -SymbolName "baremetal_main.health_history"
$healthHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_count$' -SymbolName "baremetal_main.health_history_count"
$healthHistoryHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_head$' -SymbolName "baremetal_main.health_history_head"
$healthHistoryOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_overflow$' -SymbolName "baremetal_main.health_history_overflow"
$healthHistorySeqAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_seq$' -SymbolName "baremetal_main.health_history_seq"

$artifactForGdb = $artifact.Replace('\', '/')
if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $pre_reset_phase = 0
set $pre_reset_last_seq = 0
set $pre_reset_last_tick = 0
set $pre_reset_observed_tick = 0
set $pre_reset_stack = 0
set $pre_reset_phase_changes = 0
file __ARTIFACT__
handle SIGQUIT nostop noprint pass
target remote :__GDBPORT__
break *0x__START__
commands
silent
printf "HIT_START\n"
set $stage = 1
continue
end
break *0x__SPINPAUSE__
commands
silent
if $stage == 1
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 0
    set *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) = __MODE_RUNNING__
    set *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__) = 0
    set *(unsigned short*)(0x__STATUS__+__STATUS_HEALTH_OFFSET__) = 200
    set *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) = 0
    set *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) = 0
    set *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__) = __BOOT_RUNTIME__
    set *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_BOOTSEQ_OFFSET__) = 0
    set *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_LASTSEQ_OFFSET__) = 0
    set *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_LASTTICK_OFFSET__) = 0
    set *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_OBSERVEDTICK_OFFSET__) = 0
    set *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_STACK_OFFSET__) = 0
    set *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASECHANGES_OFFSET__) = 0
    set *(unsigned int*)0x__CMD_HISTORY_COUNT__ = 0
    set *(unsigned int*)0x__CMD_HISTORY_HEAD__ = 0
    set *(unsigned int*)0x__CMD_HISTORY_OVERFLOW__ = 0
    set *(unsigned int*)0x__HEALTH_HISTORY_COUNT__ = 0
    set *(unsigned int*)0x__HEALTH_HISTORY_HEAD__ = 0
    set *(unsigned int*)0x__HEALTH_HISTORY_OVERFLOW__ = 0
    set *(unsigned int*)0x__HEALTH_HISTORY_SEQ__ = 0
    set *(unsigned short*)(0x__COMMAND__+__COMMAND_OPCODE_OFFSET__) = __SET_HEALTH_OPCODE__
    set *(unsigned int*)(0x__COMMAND__+__COMMAND_SEQ_OFFSET__) = 1
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG0_OFFSET__) = __HEALTH_CODE__
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 1
    set *(unsigned short*)(0x__COMMAND__+__COMMAND_OPCODE_OFFSET__) = __SET_BOOT_PHASE_OPCODE__
    set *(unsigned int*)(0x__COMMAND__+__COMMAND_SEQ_OFFSET__) = 2
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG0_OFFSET__) = __BOOT_INIT__
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 2
    set *(unsigned short*)(0x__COMMAND__+__COMMAND_OPCODE_OFFSET__) = __CAPTURE_STACK_OPCODE__
    set *(unsigned int*)(0x__COMMAND__+__COMMAND_SEQ_OFFSET__) = 3
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 3
    set $pre_reset_phase = *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__)
    set $pre_reset_last_seq = *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_LASTSEQ_OFFSET__)
    set $pre_reset_last_tick = *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_LASTTICK_OFFSET__)
    set $pre_reset_observed_tick = *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_OBSERVEDTICK_OFFSET__)
    set $pre_reset_stack = *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_STACK_OFFSET__)
    set $pre_reset_phase_changes = *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASECHANGES_OFFSET__)
    set *(unsigned short*)(0x__COMMAND__+__COMMAND_OPCODE_OFFSET__) = __RESET_BOOTDIAG_OPCODE__
    set *(unsigned int*)(0x__COMMAND__+__COMMAND_SEQ_OFFSET__) = 4
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 4
    printf "AFTER_RESET_BOOTDIAG\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x__COMMAND__+__COMMAND_OPCODE_OFFSET__)
    printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x__COMMAND__+__COMMAND_SEQ_OFFSET__)
    printf "PRE_RESET_PHASE=%u\n", $pre_reset_phase
    printf "PRE_RESET_LAST_SEQ=%u\n", $pre_reset_last_seq
    printf "PRE_RESET_LAST_TICK=%llu\n", $pre_reset_last_tick
    printf "PRE_RESET_OBSERVED_TICK=%llu\n", $pre_reset_observed_tick
    printf "PRE_RESET_STACK=%llu\n", $pre_reset_stack
    printf "PRE_RESET_PHASE_CHANGES=%u\n", $pre_reset_phase_changes
    printf "BOOTDIAG_PHASE=%u\n", *(unsigned char*)(0x__BOOTDIAG__+__BOOTDIAG_PHASE_OFFSET__)
    printf "BOOTDIAG_BOOT_SEQ=%u\n", *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_BOOTSEQ_OFFSET__)
    printf "BOOTDIAG_LAST_SEQ=%u\n", *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_LASTSEQ_OFFSET__)
    printf "BOOTDIAG_LAST_TICK=%llu\n", *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_LASTTICK_OFFSET__)
    printf "BOOTDIAG_OBSERVED_TICK=%llu\n", *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_OBSERVEDTICK_OFFSET__)
    printf "BOOTDIAG_STACK=%llu\n", *(unsigned long long*)(0x__BOOTDIAG__+__BOOTDIAG_STACK_OFFSET__)
    printf "BOOTDIAG_PHASE_CHANGES=%u\n", *(unsigned int*)(0x__BOOTDIAG__+__BOOTDIAG_PHASECHANGES_OFFSET__)
    printf "CMD_HISTORY_LEN=%u\n", *(unsigned int*)0x__CMD_HISTORY_COUNT__
    printf "CMD_HISTORY_HEAD=%u\n", *(unsigned int*)0x__CMD_HISTORY_HEAD__
    printf "CMD_HISTORY_OVERFLOW=%u\n", *(unsigned int*)0x__CMD_HISTORY_OVERFLOW__
    printf "CMD_HISTORY_LAST_SEQ=%u\n", *(unsigned int*)(0x__CMD_HISTORY__ + (__COMMAND_EVENT_STRIDE__ * 3) + __COMMAND_EVENT_SEQ_OFFSET__)
    printf "CMD_HISTORY_LAST_OPCODE=%u\n", *(unsigned short*)(0x__CMD_HISTORY__ + (__COMMAND_EVENT_STRIDE__ * 3) + __COMMAND_EVENT_OPCODE_OFFSET__)
    printf "CMD_HISTORY_LAST_RESULT=%d\n", *(short*)(0x__CMD_HISTORY__ + (__COMMAND_EVENT_STRIDE__ * 3) + __COMMAND_EVENT_RESULT_OFFSET__)
    printf "CMD_HISTORY_LAST_TICK=%llu\n", *(unsigned long long*)(0x__CMD_HISTORY__ + (__COMMAND_EVENT_STRIDE__ * 3) + __COMMAND_EVENT_TICK_OFFSET__)
    set *(unsigned short*)(0x__COMMAND__+__COMMAND_OPCODE_OFFSET__) = __CLEAR_COMMAND_HISTORY_OPCODE__
    set *(unsigned int*)(0x__COMMAND__+__COMMAND_SEQ_OFFSET__) = 5
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 5
    printf "AFTER_CLEAR_COMMAND_HISTORY\n"
    printf "ACK2=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE2=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT2=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS2=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "CMD_HISTORY_LEN2=%u\n", *(unsigned int*)0x__CMD_HISTORY_COUNT__
    printf "CMD_HISTORY_HEAD2=%u\n", *(unsigned int*)0x__CMD_HISTORY_HEAD__
    printf "CMD_HISTORY_OVERFLOW2=%u\n", *(unsigned int*)0x__CMD_HISTORY_OVERFLOW__
    printf "CMD_HISTORY_FIRST_SEQ=%u\n", *(unsigned int*)(0x__CMD_HISTORY__ + __COMMAND_EVENT_SEQ_OFFSET__)
    printf "CMD_HISTORY_FIRST_OPCODE=%u\n", *(unsigned short*)(0x__CMD_HISTORY__ + __COMMAND_EVENT_OPCODE_OFFSET__)
    printf "CMD_HISTORY_FIRST_RESULT=%d\n", *(short*)(0x__CMD_HISTORY__ + __COMMAND_EVENT_RESULT_OFFSET__)
    printf "CMD_HISTORY_FIRST_TICK=%llu\n", *(unsigned long long*)(0x__CMD_HISTORY__ + __COMMAND_EVENT_TICK_OFFSET__)
    printf "CMD_HISTORY_FIRST_ARG0=%llu\n", *(unsigned long long*)(0x__CMD_HISTORY__ + __COMMAND_EVENT_ARG0_OFFSET__)
    printf "CMD_HISTORY_FIRST_ARG1=%llu\n", *(unsigned long long*)(0x__CMD_HISTORY__ + __COMMAND_EVENT_ARG1_OFFSET__)
    set *(unsigned short*)(0x__COMMAND__+__COMMAND_OPCODE_OFFSET__) = __CLEAR_HEALTH_HISTORY_OPCODE__
    set *(unsigned int*)(0x__COMMAND__+__COMMAND_SEQ_OFFSET__) = 6
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 6
    printf "AFTER_CLEAR_HEALTH_HISTORY\n"
    printf "ACK3=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE3=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT3=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS3=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "HEALTH_HISTORY_LEN=%u\n", *(unsigned int*)0x__HEALTH_HISTORY_COUNT__
    printf "HEALTH_HISTORY_HEAD=%u\n", *(unsigned int*)0x__HEALTH_HISTORY_HEAD__
    printf "HEALTH_HISTORY_OVERFLOW=%u\n", *(unsigned int*)0x__HEALTH_HISTORY_OVERFLOW__
    printf "HEALTH_HISTORY_FIRST_SEQ=%u\n", *(unsigned int*)(0x__HEALTH_HISTORY__ + __HEALTH_EVENT_SEQ_OFFSET__)
    printf "HEALTH_HISTORY_FIRST_CODE=%u\n", *(unsigned short*)(0x__HEALTH_HISTORY__ + __HEALTH_EVENT_CODE_OFFSET__)
    printf "HEALTH_HISTORY_FIRST_MODE=%u\n", *(unsigned char*)(0x__HEALTH_HISTORY__ + __HEALTH_EVENT_MODE_OFFSET__)
    printf "HEALTH_HISTORY_FIRST_TICK=%llu\n", *(unsigned long long*)(0x__HEALTH_HISTORY__ + __HEALTH_EVENT_TICK_OFFSET__)
    printf "HEALTH_HISTORY_FIRST_ACK=%u\n", *(unsigned int*)(0x__HEALTH_HISTORY__ + __HEALTH_EVENT_ACK_OFFSET__)
    quit
  end
  continue
end
continue
end
continue
'@

$gdbContent = $gdbTemplate `
    -replace '__ARTIFACT__', $artifactForGdb `
    -replace '__GDBPORT__', [string]$GdbPort `
    -replace '__START__', $startAddress `
    -replace '__SPINPAUSE__', $spinPauseAddress `
    -replace '__STATUS__', $statusAddress `
    -replace '__COMMAND__', $commandMailboxAddress `
    -replace '__BOOTDIAG__', $bootDiagAddress `
    -replace '__CMD_HISTORY__', $commandHistoryAddress `
    -replace '__CMD_HISTORY_COUNT__', $commandHistoryCountAddress `
    -replace '__CMD_HISTORY_HEAD__', $commandHistoryHeadAddress `
    -replace '__CMD_HISTORY_OVERFLOW__', $commandHistoryOverflowAddress `
    -replace '__HEALTH_HISTORY__', $healthHistoryAddress `
    -replace '__HEALTH_HISTORY_COUNT__', $healthHistoryCountAddress `
    -replace '__HEALTH_HISTORY_HEAD__', $healthHistoryHeadAddress `
    -replace '__HEALTH_HISTORY_OVERFLOW__', $healthHistoryOverflowAddress `
    -replace '__HEALTH_HISTORY_SEQ__', $healthHistorySeqAddress `
    -replace '__STATUS_MODE_OFFSET__', [string]$statusModeOffset `
    -replace '__STATUS_TICKS_OFFSET__', [string]$statusTicksOffset `
    -replace '__STATUS_HEALTH_OFFSET__', [string]$statusLastHealthCodeOffset `
    -replace '__STATUS_ACK_OFFSET__', [string]$statusCommandSeqAckOffset `
    -replace '__STATUS_LAST_OPCODE_OFFSET__', [string]$statusLastCommandOpcodeOffset `
    -replace '__STATUS_LAST_RESULT_OFFSET__', [string]$statusLastCommandResultOffset `
    -replace '__COMMAND_OPCODE_OFFSET__', [string]$commandOpcodeOffset `
    -replace '__COMMAND_SEQ_OFFSET__', [string]$commandSeqOffset `
    -replace '__COMMAND_ARG0_OFFSET__', [string]$commandArg0Offset `
    -replace '__COMMAND_ARG1_OFFSET__', [string]$commandArg1Offset `
    -replace '__BOOTDIAG_PHASE_OFFSET__', [string]$bootDiagPhaseOffset `
    -replace '__BOOTDIAG_BOOTSEQ_OFFSET__', [string]$bootDiagBootSeqOffset `
    -replace '__BOOTDIAG_LASTSEQ_OFFSET__', [string]$bootDiagLastCommandSeqOffset `
    -replace '__BOOTDIAG_LASTTICK_OFFSET__', [string]$bootDiagLastCommandTickOffset `
    -replace '__BOOTDIAG_OBSERVEDTICK_OFFSET__', [string]$bootDiagLastTickObservedOffset `
    -replace '__BOOTDIAG_STACK_OFFSET__', [string]$bootDiagStackPointerSnapshotOffset `
    -replace '__BOOTDIAG_PHASECHANGES_OFFSET__', [string]$bootDiagPhaseChangesOffset `
    -replace '__COMMAND_EVENT_SEQ_OFFSET__', [string]$commandEventSeqOffset `
    -replace '__COMMAND_EVENT_OPCODE_OFFSET__', [string]$commandEventOpcodeOffset `
    -replace '__COMMAND_EVENT_RESULT_OFFSET__', [string]$commandEventResultOffset `
    -replace '__COMMAND_EVENT_TICK_OFFSET__', [string]$commandEventTickOffset `
    -replace '__COMMAND_EVENT_ARG0_OFFSET__', [string]$commandEventArg0Offset `
    -replace '__COMMAND_EVENT_ARG1_OFFSET__', [string]$commandEventArg1Offset `
    -replace '__COMMAND_EVENT_STRIDE__', [string]$commandEventStride `
    -replace '__HEALTH_EVENT_SEQ_OFFSET__', [string]$healthEventSeqOffset `
    -replace '__HEALTH_EVENT_CODE_OFFSET__', [string]$healthEventCodeOffset `
    -replace '__HEALTH_EVENT_MODE_OFFSET__', [string]$healthEventModeOffset `
    -replace '__HEALTH_EVENT_TICK_OFFSET__', [string]$healthEventTickOffset `
    -replace '__HEALTH_EVENT_ACK_OFFSET__', [string]$healthEventAckOffset `
    -replace '__SET_HEALTH_OPCODE__', [string]$setHealthCodeOpcode `
    -replace '__SET_BOOT_PHASE_OPCODE__', [string]$setBootPhaseOpcode `
    -replace '__RESET_BOOTDIAG_OPCODE__', [string]$resetBootDiagnosticsOpcode `
    -replace '__CAPTURE_STACK_OPCODE__', [string]$captureStackPointerOpcode `
    -replace '__CLEAR_COMMAND_HISTORY_OPCODE__', [string]$clearCommandHistoryOpcode `
    -replace '__CLEAR_HEALTH_HISTORY_OPCODE__', [string]$clearHealthHistoryOpcode `
    -replace '__HEALTH_CODE__', [string]$healthCode `
    -replace '__BOOT_INIT__', [string]$bootPhaseInit `
    -replace '__BOOT_RUNTIME__', [string]$bootPhaseRuntime `
    -replace '__MODE_RUNNING__', [string]$modeRunning

$gdbContent | Set-Content -Path $gdbScript -Encoding Ascii

$qemuArgs = @("-kernel", $artifact, "-nographic", "-no-reboot", "-no-shutdown", "-serial", "none", "-monitor", "none", "-S", "-gdb", "tcp::$GdbPort")
$qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
Start-Sleep -Milliseconds 700
$gdbProc = Start-Process -FilePath $gdb -ArgumentList @("-q", "-batch", "-x", $gdbScript) -PassThru -NoNewWindow -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr

$timedOut = $false
try {
    $null = Wait-Process -Id $gdbProc.Id -Timeout $TimeoutSeconds -ErrorAction Stop
} catch {
    $timedOut = $true
    try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
} finally {
    try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

$gdbOutput = if (Test-Path $gdbStdout) { Get-Content -Raw $gdbStdout } else { "" }
$gdbError = if (Test-Path $gdbStderr) { Get-Content -Raw $gdbStderr } else { "" }

if ($timedOut) {
    throw "GDB timed out while probing bootdiag/history clear semantics. stdout: $gdbOutput stderr: $gdbError"
}

foreach ($marker in @("HIT_START", "AFTER_RESET_BOOTDIAG", "AFTER_CLEAR_COMMAND_HISTORY", "AFTER_CLEAR_HEALTH_HISTORY")) {
    if ($gdbOutput -notmatch [regex]::Escape($marker)) {
        throw "Missing checkpoint '$marker' in bootdiag/history clear probe output. stdout: $gdbOutput stderr: $gdbError"
    }
}

$expectations = @{
    ACK = 4
    LAST_OPCODE = $resetBootDiagnosticsOpcode
    LAST_RESULT = 0
    MAILBOX_OPCODE = $resetBootDiagnosticsOpcode
    MAILBOX_SEQ = 4
    PRE_RESET_PHASE = $bootPhaseInit
    PRE_RESET_LAST_SEQ = 3
    PRE_RESET_LAST_TICK = 2
    PRE_RESET_OBSERVED_TICK = 3
    PRE_RESET_PHASE_CHANGES = 1
    BOOTDIAG_PHASE = $bootPhaseRuntime
    BOOTDIAG_BOOT_SEQ = 1
    BOOTDIAG_LAST_SEQ = 4
    BOOTDIAG_LAST_TICK = 3
    BOOTDIAG_OBSERVED_TICK = 4
    BOOTDIAG_STACK = 0
    BOOTDIAG_PHASE_CHANGES = 0
    CMD_HISTORY_LEN = 4
    CMD_HISTORY_HEAD = 4
    CMD_HISTORY_OVERFLOW = 0
    CMD_HISTORY_LAST_SEQ = 4
    CMD_HISTORY_LAST_OPCODE = $resetBootDiagnosticsOpcode
    CMD_HISTORY_LAST_RESULT = 0
    CMD_HISTORY_LAST_TICK = 3
    ACK2 = 5
    LAST_OPCODE2 = $clearCommandHistoryOpcode
    LAST_RESULT2 = 0
    CMD_HISTORY_LEN2 = 1
    CMD_HISTORY_HEAD2 = 1
    CMD_HISTORY_OVERFLOW2 = 0
    CMD_HISTORY_FIRST_SEQ = 5
    CMD_HISTORY_FIRST_OPCODE = $clearCommandHistoryOpcode
    CMD_HISTORY_FIRST_RESULT = 0
    CMD_HISTORY_FIRST_TICK = 4
    CMD_HISTORY_FIRST_ARG0 = 0
    CMD_HISTORY_FIRST_ARG1 = 0
    ACK3 = 6
    LAST_OPCODE3 = $clearHealthHistoryOpcode
    LAST_RESULT3 = 0
    HEALTH_HISTORY_LEN = 1
    HEALTH_HISTORY_HEAD = 1
    HEALTH_HISTORY_OVERFLOW = 0
    HEALTH_HISTORY_FIRST_SEQ = 1
    HEALTH_HISTORY_FIRST_CODE = 200
    HEALTH_HISTORY_FIRST_MODE = $modeRunning
    HEALTH_HISTORY_FIRST_TICK = 6
    HEALTH_HISTORY_FIRST_ACK = 6
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

foreach ($field in @("TICKS", "TICKS2", "TICKS3")) {
    $actual = Extract-IntValue -Text $gdbOutput -Name $field
    if ($null -eq $actual) {
        throw "Missing expected field '$field' in probe output. stdout: $gdbOutput stderr: $gdbError"
    }
}

$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$ticks2 = Extract-IntValue -Text $gdbOutput -Name "TICKS2"
$ticks3 = Extract-IntValue -Text $gdbOutput -Name "TICKS3"
if ($ticks -lt 4 -or $ticks2 -lt 5 -or $ticks3 -lt 6) {
    throw "Unexpected tick progression in probe output. TICKS=$ticks TICKS2=$ticks2 TICKS3=$ticks3 stdout: $gdbOutput stderr: $gdbError"
}

$preResetStack = Extract-IntValue -Text $gdbOutput -Name "PRE_RESET_STACK"
if ($null -eq $preResetStack -or $preResetStack -le 0) {
    throw "Expected PRE_RESET_STACK to be non-zero. stdout: $gdbOutput stderr: $gdbError"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_BOOTDIAG_HISTORY_CLEAR_PROBE=pass"
$gdbOutput.TrimEnd()
