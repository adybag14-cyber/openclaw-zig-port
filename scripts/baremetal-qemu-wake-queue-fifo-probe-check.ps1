param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskTerminateOpcode = 28
$wakeQueueClearOpcode = 44
$schedulerWakeTaskOpcode = 45
$taskWaitOpcode = 50
$taskResumeOpcode = 51
$wakeQueuePopOpcode = 54

$taskBudget = 5
$expectedTaskPriority = 0

$taskStateReady = 1
$taskStateTerminated = 4
$taskStateWaiting = 6
$wakeReasonManual = 3
$resultNotFound = -2

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$schedulerTaskCountOffset = 1

$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5

$wakeEventStride = 32
$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventReasonOffset = 12
$wakeEventTickOffset = 16

function Resolve-ZigExecutable {
    $defaultWindowsZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
    if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) {
        if (-not (Test-Path $env:OPENCLAW_ZIG_BIN)) {
            throw "OPENCLAW_ZIG_BIN is set but not found: $($env:OPENCLAW_ZIG_BIN)"
        }
        return $env:OPENCLAW_ZIG_BIN
    }

    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($null -ne $zigCmd -and $zigCmd.Path) {
        return $zigCmd.Path
    }

    if (Test-Path $defaultWindowsZig) {
        return $defaultWindowsZig
    }

    throw "Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure zig is on PATH."
}

function Resolve-QemuExecutable {
    $candidates = @(
        "qemu-system-x86_64",
        "qemu-system-x86_64.exe",
        "C:\Program Files\qemu\qemu-system-x86_64.exe"
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

function Resolve-GdbExecutable {
    $candidates = @(
        "gdb",
        "gdb.exe"
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
    }

    return $null
}

function Resolve-NmExecutable {
    $candidates = @(
        "llvm-nm",
        "llvm-nm.exe",
        "nm",
        "nm.exe",
        "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\llvm-nm.exe"
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

function Resolve-ClangExecutable {
    $candidates = @(
        "clang",
        "clang.exe",
        "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\clang.exe"
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

function Resolve-LldExecutable {
    $candidates = @(
        "lld",
        "lld.exe",
        "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\lld.exe"
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

function Resolve-ZigGlobalCacheDir {
    $candidates = @()
    if ($env:ZIG_GLOBAL_CACHE_DIR -and $env:ZIG_GLOBAL_CACHE_DIR.Trim().Length -gt 0) {
        $candidates += $env:ZIG_GLOBAL_CACHE_DIR
    }
    if ($env:LOCALAPPDATA -and $env:LOCALAPPDATA.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:LOCALAPPDATA "zig")
    }
    if ($env:XDG_CACHE_HOME -and $env:XDG_CACHE_HOME.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:XDG_CACHE_HOME "zig")
    }
    if ($env:HOME -and $env:HOME.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:HOME ".cache/zig")
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return (Join-Path $repo ".zig-global-cache")
}

function Resolve-CompilerRtArchive {
    $cacheRoots = @()
    $primary = Resolve-ZigGlobalCacheDir
    if (-not [string]::IsNullOrWhiteSpace($primary)) {
        $cacheRoots += $primary
    }

    $candidate = $null
    foreach ($cacheRoot in $cacheRoots) {
        $localZigObjRoot = Join-Path $cacheRoot "o"
        if (-not (Test-Path $localZigObjRoot)) {
            continue
        }

        $candidate = Get-ChildItem -Path $localZigObjRoot -Recurse -Filter "libcompiler_rt.a" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1

        if ($null -ne $candidate) {
            return $candidate.FullName
        }
    }

    return $null
}

function Resolve-SymbolAddress {
    param(
        [string[]] $SymbolLines,
        [string] $Pattern,
        [string] $SymbolName
    )

    $line = $SymbolLines | Where-Object { $_ -match $Pattern } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "Failed to resolve symbol address for $SymbolName"
    }

    $parts = ($line.Trim() -split '\s+')
    if ($parts.Count -lt 3) {
        throw "Unexpected symbol line while resolving ${SymbolName}: $line"
    }

    return $parts[0]
}

function Extract-IntValue {
    param(
        [string] $Text,
        [string] $Name
    )

    $pattern = [regex]::Escape($Name) + '=(-?\d+)'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        return $null
    }

    return [int64]::Parse($match.Groups[1].Value)
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$zig = Resolve-ZigExecutable
$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable
$clang = Resolve-ClangExecutable
$lld = Resolve-LldExecutable
$compilerRt = Resolve-CompilerRtArchive
$zigGlobalCacheDir = Resolve-ZigGlobalCacheDir
$zigLocalCacheDir = if ($env:ZIG_LOCAL_CACHE_DIR -and $env:ZIG_LOCAL_CACHE_DIR.Trim().Length -gt 0) { $env:ZIG_LOCAL_CACHE_DIR } else { Join-Path $repo ".zig-cache" }

if ($null -eq $qemu -or $null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=$([bool]($null -ne $qemu))"
    Write-Output "BAREMETAL_GDB_AVAILABLE=$([bool]($null -ne $gdb))"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE=skipped"
    return
}

if ($null -eq $clang -or $null -eq $lld -or $null -eq $compilerRt) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=False"
    if ($null -eq $clang) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=clang" }
    if ($null -eq $lld) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=lld" }
    if ($null -eq $compilerRt) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=libcompiler_rt.a" }
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-wake-queue-fifo-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-wake-queue-fifo-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-wake-queue-fifo-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-wake-queue-fifo-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-wake-queue-fifo-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-wake-queue-fifo-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-wake-queue-fifo-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-wake-queue-fifo-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-wake-queue-fifo-probe.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null

    @"
pub const qemu_smoke: bool = false;`r`npub const console_probe_banner: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii

    & $zig build-obj `
        -fno-strip `
        -fsingle-threaded `
        -ODebug `
        -target x86_64-freestanding-none `
        -mcpu baseline `
        --dep build_options `
        "-Mroot=$repo\src\baremetal_main.zig" `
        "-Mbuild_options=$optionsPath" `
        --cache-dir "$zigLocalCacheDir" `
        --global-cache-dir "$zigGlobalCacheDir" `
        --name "openclaw-zig-baremetal-main-wake-queue-fifo-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for wake-queue-fifo probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for wake-queue-fifo probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for wake-queue-fifo probe PVH artifact failed with exit code $LASTEXITCODE"
    }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) {
    throw "Failed to resolve symbol table from $artifact using $nm"
}

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
$schedulerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_state$' -SymbolName "baremetal_main.scheduler_state"
$schedulerTasksAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_tasks$' -SymbolName "baremetal_main.scheduler_tasks"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$wakeQueueTailAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_tail$' -SymbolName "baremetal_main.wake_queue_tail"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$task_id = 0
set `$pre_len = 0
set `$pre_wake0_seq = 0
set `$pre_wake0_task = 0
set `$pre_wake0_reason = 0
set `$pre_wake0_tick = 0
set `$pre_wake1_seq = 0
set `$pre_wake1_task = 0
set `$pre_wake1_reason = 0
set `$pre_wake1_tick = 0
set `$post_pop1_len = 0
set `$post_pop1_slot = 0
set `$post_pop1_seq = 0
set `$post_pop1_task = 0
set `$post_pop1_reason = 0
set `$post_pop1_tick = 0
set `$post_pop2_len = 0
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START\n"
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerResetOpcode
set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
set `$stage = 1
continue
end
break *0x$spinPauseAddress
commands
silent
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $expectedTaskPriority
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskResumeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$wakeQueueCountAddress) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskResumeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned int*)(0x$wakeQueueCountAddress) == 2
    set `$pre_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$pre_wake0_seq = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
    set `$pre_wake0_task = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    set `$pre_wake0_reason = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    set `$pre_wake0_tick = *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    set `$pre_wake1_seq = *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventSeqOffset)
    set `$pre_wake1_task = *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTaskIdOffset)
    set `$pre_wake1_reason = *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventReasonOffset)
    set `$pre_wake1_tick = *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTickOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == 0 && *(unsigned int*)(0x$wakeQueueCountAddress) == 1
    set `$post_pop1_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$post_pop1_slot = *(unsigned int*)(0x$wakeQueueTailAddress)
    set `$post_pop1_seq = *(unsigned int*)(0x$wakeQueueAddress+(`$post_pop1_slot*$wakeEventStride)+$wakeEventSeqOffset)
    set `$post_pop1_task = *(unsigned int*)(0x$wakeQueueAddress+(`$post_pop1_slot*$wakeEventStride)+$wakeEventTaskIdOffset)
    set `$post_pop1_reason = *(unsigned char*)(0x$wakeQueueAddress+(`$post_pop1_slot*$wakeEventStride)+$wakeEventReasonOffset)
    set `$post_pop1_tick = *(unsigned long long*)(0x$wakeQueueAddress+(`$post_pop1_slot*$wakeEventStride)+$wakeEventTickOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == 0 && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set `$post_pop2_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 11
  end
  continue
end
printf "AFTER_WAKE_QUEUE_FIFO\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
printf "TASK_ID=%u\n", `$task_id
printf "TASK_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "TASK_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "SCHED_TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "PRE_LEN=%u\n", `$pre_len
printf "PRE_WAKE0_SEQ=%u\n", `$pre_wake0_seq
printf "PRE_WAKE0_TASK=%u\n", `$pre_wake0_task
printf "PRE_WAKE0_REASON=%u\n", `$pre_wake0_reason
printf "PRE_WAKE0_TICK=%llu\n", `$pre_wake0_tick
printf "PRE_WAKE1_SEQ=%u\n", `$pre_wake1_seq
printf "PRE_WAKE1_TASK=%u\n", `$pre_wake1_task
printf "PRE_WAKE1_REASON=%u\n", `$pre_wake1_reason
printf "PRE_WAKE1_TICK=%llu\n", `$pre_wake1_tick
printf "POST_POP1_LEN=%u\n", `$post_pop1_len
printf "POST_POP1_SEQ=%u\n", `$post_pop1_seq
printf "POST_POP1_TASK=%u\n", `$post_pop1_task
printf "POST_POP1_REASON=%u\n", `$post_pop1_reason
printf "POST_POP1_TICK=%llu\n", `$post_pop1_tick
printf "POST_POP2_LEN=%u\n", `$post_pop2_len
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
quit
end
continue
"@ | Set-Content -Path $gdbScript -Encoding Ascii

$qemuArgs = @(
    "-kernel", $artifact,
    "-nographic",
    "-no-reboot",
    "-no-shutdown",
    "-serial", "none",
    "-monitor", "none",
    "-S",
    "-gdb", "tcp::$GdbPort"
)

$qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
Start-Sleep -Milliseconds 700

$gdbArgs = @(
    "-q",
    "-batch",
    "-x", $gdbScript
)

$gdbProc = Start-Process -FilePath $gdb -ArgumentList $gdbArgs -PassThru -NoNewWindow -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr

$timedOut = $false

try {
    $null = Wait-Process -Id $gdbProc.Id -Timeout $TimeoutSeconds -ErrorAction Stop
}
catch {
    $timedOut = $true
    try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}
finally {
    try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

$hitStart = $false
$hitAfterWakeQueueFifo = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$taskId = $null
$taskState = $null
$taskPriority = $null
$schedTaskCount = $null
$preLen = $null
$preWake0Seq = $null
$preWake0Task = $null
$preWake0Reason = $null
$preWake0Tick = $null
$preWake1Seq = $null
$preWake1Task = $null
$preWake1Reason = $null
$preWake1Tick = $null
$postPop1Len = $null
$postPop1Seq = $null
$postPop1Task = $null
$postPop1Reason = $null
$postPop1Tick = $null
$postPop2Len = $null
$wakeQueueCount = $null
$gdbOutput = ""
$gdbError = ""

if (Test-Path $gdbStdout) {
    $gdbOutput = Get-Content -Path $gdbStdout -Raw
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfterWakeQueueFifo = $gdbOutput.Contains("AFTER_WAKE_QUEUE_FIFO")
    $ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_SEQ"
    $taskId = Extract-IntValue -Text $gdbOutput -Name "TASK_ID"
    $taskState = Extract-IntValue -Text $gdbOutput -Name "TASK_STATE"
    $taskPriority = Extract-IntValue -Text $gdbOutput -Name "TASK_PRIORITY"
    $schedTaskCount = Extract-IntValue -Text $gdbOutput -Name "SCHED_TASK_COUNT"
    $preLen = Extract-IntValue -Text $gdbOutput -Name "PRE_LEN"
    $preWake0Seq = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE0_SEQ"
    $preWake0Task = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE0_TASK"
    $preWake0Reason = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE0_REASON"
    $preWake0Tick = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE0_TICK"
    $preWake1Seq = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE1_SEQ"
    $preWake1Task = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE1_TASK"
    $preWake1Reason = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE1_REASON"
    $preWake1Tick = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE1_TICK"
    $postPop1Len = Extract-IntValue -Text $gdbOutput -Name "POST_POP1_LEN"
    $postPop1Seq = Extract-IntValue -Text $gdbOutput -Name "POST_POP1_SEQ"
    $postPop1Task = Extract-IntValue -Text $gdbOutput -Name "POST_POP1_TASK"
    $postPop1Reason = Extract-IntValue -Text $gdbOutput -Name "POST_POP1_REASON"
    $postPop1Tick = Extract-IntValue -Text $gdbOutput -Name "POST_POP1_TICK"
    $postPop2Len = Extract-IntValue -Text $gdbOutput -Name "POST_POP2_LEN"
    $wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
}
if (Test-Path $gdbStderr) {
    $gdbError = Get-Content -Path $gdbStderr -Raw
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_PVH_CLANG=$clang"
Write-Output "BAREMETAL_QEMU_PVH_LLD=$lld"
Write-Output "BAREMETAL_QEMU_PVH_COMPILER_RT=$compilerRt"
Write-Output "BAREMETAL_QEMU_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_SCHEDULER_STATE_ADDR=0x$schedulerStateAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_TASKS_ADDR=0x$schedulerTasksAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_WAKE_QUEUE_COUNT_ADDR=0x$wakeQueueCountAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_HIT_AFTER_FIFO=$hitAfterWakeQueueFifo"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_TASK_ID=$taskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_TASK_STATE=$taskState"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_TASK_PRIORITY=$taskPriority"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_LEN=$preLen"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE0_SEQ=$preWake0Seq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE0_TASK=$preWake0Task"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE0_REASON=$preWake0Reason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE0_TICK=$preWake0Tick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE1_SEQ=$preWake1Seq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE1_TASK=$preWake1Task"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE1_REASON=$preWake1Reason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_PRE_WAKE1_TICK=$preWake1Tick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_POST_POP1_LEN=$postPop1Len"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_POST_POP1_SEQ=$postPop1Seq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_POST_POP1_TASK=$postPop1Task"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_POST_POP1_REASON=$postPop1Reason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_POST_POP1_TICK=$postPop1Tick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_POST_POP2_LEN=$postPop2Len"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE_TIMED_OUT=$timedOut"

$probePassed = (
    $hitStart -and
    $hitAfterWakeQueueFifo -and
    (-not $timedOut) -and
    $ack -eq 11 -and
    $lastOpcode -eq $wakeQueuePopOpcode -and
    $lastResult -eq $resultNotFound -and
    $mailboxOpcode -eq $wakeQueuePopOpcode -and
    $mailboxSeq -eq 11 -and
    $taskId -eq 1 -and
    $taskState -eq $taskStateReady -and
    $taskPriority -eq $expectedTaskPriority -and
    $schedTaskCount -eq 1 -and
    $preLen -eq 2 -and
    $preWake0Task -eq 1 -and
    $preWake1Task -eq 1 -and
    $preWake0Reason -eq $wakeReasonManual -and
    $preWake1Reason -eq $wakeReasonManual -and
    $preWake1Seq -gt $preWake0Seq -and
    $preWake1Tick -gt $preWake0Tick -and
    $postPop1Len -eq 1 -and
    $postPop1Seq -eq $preWake1Seq -and
    $postPop1Task -eq $preWake1Task -and
    $postPop1Reason -eq $preWake1Reason -and
    $postPop1Tick -eq $preWake1Tick -and
    $postPop2Len -eq 0 -and
    $wakeQueueCount -eq 0
)

Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_FIFO_PROBE=$($(if ($probePassed) { 'pass' } else { 'fail' }))"
if ($probePassed) {
    exit 0
}

if ($gdbOutput.Length -gt 0) {
    Write-Output $gdbOutput
}
if ($gdbError.Length -gt 0) {
    Write-Output $gdbError
}
if (Test-Path $qemuStderr) {
    Get-Content -Path $qemuStderr -Tail 80
}
exit 1


