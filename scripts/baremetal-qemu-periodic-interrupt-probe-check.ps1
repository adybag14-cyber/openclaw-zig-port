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
$timerResetOpcode = 41
$wakeQueueClearOpcode = 44
$timerEnableOpcode = 46
$timerDisableOpcode = 47
$timerSetQuantumOpcode = 48
$timerSchedulePeriodicOpcode = 49
$timerCancelTaskOpcode = 52
$taskCreateOpcode = 27
$taskWaitInterruptForOpcode = 58
$triggerInterruptOpcode = 7
$resetInterruptCountersOpcode = 8

$timerQuantum = 2
$periodicTaskBudget = 8
$periodicTaskPriority = 1
$interruptTaskBudget = 5
$interruptTaskPriority = 0
$periodicDelay = 2
$interruptTimeoutTicks = 6
$interruptVector = 31
$postDeadlineSlackTicks = 2

$waitConditionNone = 0
$waitConditionInterruptAny = 3
$taskStateReady = 1
$taskStateWaiting = 6
$timerEntryStateArmed = 1
$timerEntryStateCanceled = 3
$wakeReasonTimer = 1
$wakeReasonInterrupt = 2
$timerStateEnabled = 1

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$schedulerTaskCountOffset = 1
$taskStride = 40

$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetOffset = 12
$taskBudgetRemainingOffset = 16

$timerEnabledOffset = 0
$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerDispatchCountOffset = 8
$timerLastInterruptCountOffset = 24
$timerLastWakeTickOffset = 32
$timerQuantumOffset = 40

$timerEntryTimerIdOffset = 0
$timerEntryTaskIdOffset = 4
$timerEntryStateOffset = 8
$timerEntryReasonOffset = 9
$timerEntryFlagsOffset = 10
$timerEntryPeriodTicksOffset = 12
$timerEntryNextFireTickOffset = 16
$timerEntryFireCountOffset = 24
$timerEntryLastFireTickOffset = 32

$wakeEventStride = 32
$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventTimerIdOffset = 8
$wakeEventReasonOffset = 12
$wakeEventVectorOffset = 13
$wakeEventTickOffset = 16

$interruptStateLastInterruptVectorOffset = 2
$interruptStateInterruptCountOffset = 16

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

    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
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
    Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-periodic-interrupt-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-periodic-interrupt-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-periodic-interrupt-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-periodic-interrupt-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-periodic-interrupt-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-periodic-interrupt-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-periodic-interrupt-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-periodic-interrupt-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-periodic-interrupt-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-periodic-interrupt-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for periodic-interrupt probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for periodic-interrupt probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for periodic-interrupt probe PVH artifact failed with exit code $LASTEXITCODE"
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
$schedulerWaitKindAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_kind$' -SymbolName "baremetal_main.scheduler_wait_kind"
$schedulerWaitInterruptVectorAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_interrupt_vector$' -SymbolName "baremetal_main.scheduler_wait_interrupt_vector"
$schedulerWaitTimeoutTickAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_timeout_tick$' -SymbolName "baremetal_main.scheduler_wait_timeout_tick"
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName "baremetal_main.timer_state"
$timerEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_entries$' -SymbolName "baremetal_main.timer_entries"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$interruptStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_state$' -SymbolName "baremetal.x86_bootstrap.interrupt_state"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$interrupt_deadline = 0
set `$first_fire_count = 0
set `$first_dispatch_count = 0
set `$first_wake_count = 0
set `$first_last_fire_tick = 0
set `$interrupt_wake_tick = 0
set `$second_fire_count = 0
set `$second_dispatch_count = 0
set `$second_wake_count = 0
set `$second_tick = 0
set `$second_last_fire_tick = 0
set `$second_next_fire_tick = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetInterruptCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerSetQuantumOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $timerQuantum
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $periodicTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $periodicTaskPriority
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptTaskPriority
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerSchedulePeriodicOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $periodicDelay
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset) == $timerEntryStateArmed && *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTaskIdOffset) == 1 && *(unsigned int*)(0x$timerEntriesAddress+$timerEntryPeriodTicksOffset) == $periodicDelay && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptTimeoutTicks
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10 && *(unsigned char*)(0x$schedulerTasksAddress+($taskStride*1)+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress+1) == $waitConditionInterruptAny && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress+8) > *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set `$interrupt_deadline = *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress+8)
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset) >= 1 && *(unsigned int*)(0x$wakeQueueCountAddress) >= 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerTasksAddress+($taskStride*1)+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress+1) == $waitConditionInterruptAny && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress+8) == `$interrupt_deadline && *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset) == $timerEntryStateArmed && *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryNextFireTickOffset) > *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$first_fire_count = *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset)
    set `$first_dispatch_count = *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    set `$first_wake_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$first_last_fire_tick = *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryLastFireTickOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11 && *(unsigned int*)(0x$wakeQueueCountAddress) == (`$first_wake_count + 1) && *(unsigned char*)(0x$schedulerTasksAddress+($taskStride*1)+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerWaitKindAddress+1) == $waitConditionNone && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress+8) == 0 && *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset) == `$first_fire_count && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset) == 1 && *(unsigned short*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset) == $interruptVector
    set `$interrupt_wake_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$stage = 13
  end
  continue
end
if `$stage == 13
  if *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset) == (`$first_fire_count + 1) && *(unsigned int*)(0x$wakeQueueCountAddress) == (`$first_wake_count + 2) && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == (`$first_dispatch_count + 1) && *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset) == $timerEntryStateArmed && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady
    set `$second_fire_count = *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset)
    set `$second_dispatch_count = *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    set `$second_wake_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$second_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$second_last_fire_tick = *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryLastFireTickOffset)
    set `$second_next_fire_tick = *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryNextFireTickOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerCancelTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 14
  end
  continue
end
if `$stage == 14
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12 && *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset) == $timerEntryStateCanceled && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 0 && *(unsigned int*)(0x$wakeQueueCountAddress) == `$second_wake_count
    set `$stage = 15
  end
  continue
end
if `$stage == 15
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= (`$interrupt_deadline + $postDeadlineSlackTicks) && *(unsigned int*)(0x$wakeQueueCountAddress) == `$second_wake_count && *(unsigned char*)(0x$schedulerTasksAddress+($taskStride*1)+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerWaitKindAddress+1) == $waitConditionNone && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress+8) == 0 && *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset) == `$second_fire_count && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == `$second_dispatch_count
    set `$stage = 16
  end
  continue
end
printf "AFTER_PERIODIC_INTERRUPT\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
printf "SCHED_TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "TASK0_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
printf "TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "TASK0_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "TASK0_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
printf "TASK0_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetOffset)
printf "TASK0_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
printf "TASK1_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+($taskStride*1)+$taskIdOffset)
printf "TASK1_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+($taskStride*1)+$taskStateOffset)
printf "TASK1_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+($taskStride*1)+$taskPriorityOffset)
printf "TASK1_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+($taskStride*1)+$taskRunCountOffset)
printf "TASK1_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+($taskStride*1)+$taskBudgetOffset)
printf "TASK1_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+($taskStride*1)+$taskBudgetRemainingOffset)
printf "WAIT_KIND0=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress)
printf "WAIT_VECTOR0=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
printf "WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
printf "WAIT_KIND1=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress+1)
printf "WAIT_VECTOR1=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress+1)
printf "WAIT_TIMEOUT1=%llu\n", *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress+8)
printf "INTERRUPT_DEADLINE=%llu\n", `$interrupt_deadline
printf "INTERRUPT_WAKE_TICK=%llu\n", `$interrupt_wake_tick
printf "TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
printf "TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
printf "TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
printf "TIMER_LAST_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastInterruptCountOffset)
printf "TIMER_LAST_WAKE_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
printf "TIMER_QUANTUM=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
printf "TIMER0_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
printf "TIMER0_TASK_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTaskIdOffset)
printf "TIMER0_STATE=%u\n", *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset)
printf "TIMER0_REASON=%u\n", *(unsigned char*)(0x$timerEntriesAddress+$timerEntryReasonOffset)
printf "TIMER0_FLAGS=%u\n", *(unsigned short*)(0x$timerEntriesAddress+$timerEntryFlagsOffset)
printf "TIMER0_PERIOD_TICKS=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryPeriodTicksOffset)
printf "TIMER0_NEXT_FIRE_TICK=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryNextFireTickOffset)
printf "TIMER0_FIRE_COUNT=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset)
printf "TIMER0_LAST_FIRE_TICK=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryLastFireTickOffset)
printf "FIRST_FIRE_COUNT=%llu\n", `$first_fire_count
printf "FIRST_DISPATCH_COUNT=%llu\n", `$first_dispatch_count
printf "FIRST_WAKE_COUNT=%u\n", `$first_wake_count
printf "FIRST_LAST_FIRE_TICK=%llu\n", `$first_last_fire_tick
printf "SECOND_FIRE_COUNT=%llu\n", `$second_fire_count
printf "SECOND_DISPATCH_COUNT=%llu\n", `$second_dispatch_count
printf "SECOND_WAKE_COUNT=%u\n", `$second_wake_count
printf "SECOND_TICK=%llu\n", `$second_tick
printf "SECOND_LAST_FIRE_TICK=%llu\n", `$second_last_fire_tick
printf "SECOND_NEXT_FIRE_TICK=%llu\n", `$second_next_fire_tick
printf "WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
printf "WAKE1_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventSeqOffset)
printf "WAKE1_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTaskIdOffset)
printf "WAKE1_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTimerIdOffset)
printf "WAKE1_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventReasonOffset)
printf "WAKE1_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventVectorOffset)
printf "WAKE1_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTickOffset)
printf "WAKE2_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventSeqOffset)
printf "WAKE2_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventTaskIdOffset)
printf "WAKE2_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventTimerIdOffset)
printf "WAKE2_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventReasonOffset)
printf "WAKE2_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventVectorOffset)
printf "WAKE2_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventTickOffset)
printf "INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
printf "LAST_INTERRUPT_VECTOR=%u\n", *(unsigned short*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset)
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
$hitAfterPeriodicInterrupt = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$schedulerTaskCount = $null
$task0Id = $null
$task0State = $null
$task0Priority = $null
$task0RunCount = $null
$task0Budget = $null
$task0BudgetRemaining = $null
$task1Id = $null
$task1State = $null
$task1Priority = $null
$task1RunCount = $null
$task1Budget = $null
$task1BudgetRemaining = $null
$waitKind0 = $null
$waitVector0 = $null
$waitTimeout0 = $null
$waitKind1 = $null
$waitVector1 = $null
$waitTimeout1 = $null
$interruptDeadline = $null
$interruptWakeTick = $null
$timerEnabled = $null
$timerEntryCount = $null
$timerPendingWakeCount = $null
$timerDispatchCount = $null
$timerLastInterruptCount = $null
$timerLastWakeTick = $null
$timerQuantumOut = $null
$wakeQueueCount = $null
$timer0Id = $null
$timer0TaskId = $null
$timer0State = $null
$timer0Reason = $null
$timer0Flags = $null
$timer0PeriodTicks = $null
$timer0NextFireTick = $null
$timer0FireCount = $null
$timer0LastFireTick = $null
$firstFireCount = $null
$firstDispatchCount = $null
$firstWakeCount = $null
$firstLastFireTick = $null
$secondFireCount = $null
$secondDispatchCount = $null
$secondWakeCount = $null
$secondTick = $null
$secondLastFireTick = $null
$secondNextFireTick = $null
$wake0Seq = $null
$wake0TaskId = $null
$wake0TimerId = $null
$wake0Reason = $null
$wake0Vector = $null
$wake0Tick = $null
$wake1Seq = $null
$wake1TaskId = $null
$wake1TimerId = $null
$wake1Reason = $null
$wake1Vector = $null
$wake1Tick = $null
$wake2Seq = $null
$wake2TaskId = $null
$wake2TimerId = $null
$wake2Reason = $null
$wake2Vector = $null
$wake2Tick = $null
$interruptCount = $null
$lastInterruptVector = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterPeriodicInterrupt = $out -match "AFTER_PERIODIC_INTERRUPT"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $schedulerTaskCount = Extract-IntValue -Text $out -Name "SCHED_TASK_COUNT"
    $task0Id = Extract-IntValue -Text $out -Name "TASK0_ID"
    $task0State = Extract-IntValue -Text $out -Name "TASK0_STATE"
    $task0Priority = Extract-IntValue -Text $out -Name "TASK0_PRIORITY"
    $task0RunCount = Extract-IntValue -Text $out -Name "TASK0_RUN_COUNT"
    $task0Budget = Extract-IntValue -Text $out -Name "TASK0_BUDGET"
    $task0BudgetRemaining = Extract-IntValue -Text $out -Name "TASK0_BUDGET_REMAINING"
    $task1Id = Extract-IntValue -Text $out -Name "TASK1_ID"
    $task1State = Extract-IntValue -Text $out -Name "TASK1_STATE"
    $task1Priority = Extract-IntValue -Text $out -Name "TASK1_PRIORITY"
    $task1RunCount = Extract-IntValue -Text $out -Name "TASK1_RUN_COUNT"
    $task1Budget = Extract-IntValue -Text $out -Name "TASK1_BUDGET"
    $task1BudgetRemaining = Extract-IntValue -Text $out -Name "TASK1_BUDGET_REMAINING"
    $waitKind0 = Extract-IntValue -Text $out -Name "WAIT_KIND0"
    $waitVector0 = Extract-IntValue -Text $out -Name "WAIT_VECTOR0"
    $waitTimeout0 = Extract-IntValue -Text $out -Name "WAIT_TIMEOUT0"
    $waitKind1 = Extract-IntValue -Text $out -Name "WAIT_KIND1"
    $waitVector1 = Extract-IntValue -Text $out -Name "WAIT_VECTOR1"
    $waitTimeout1 = Extract-IntValue -Text $out -Name "WAIT_TIMEOUT1"
    $interruptDeadline = Extract-IntValue -Text $out -Name "INTERRUPT_DEADLINE"
    $interruptWakeTick = Extract-IntValue -Text $out -Name "INTERRUPT_WAKE_TICK"
    $timerEnabled = Extract-IntValue -Text $out -Name "TIMER_ENABLED"
    $timerEntryCount = Extract-IntValue -Text $out -Name "TIMER_ENTRY_COUNT"
    $timerPendingWakeCount = Extract-IntValue -Text $out -Name "TIMER_PENDING_WAKE_COUNT"
    $timerDispatchCount = Extract-IntValue -Text $out -Name "TIMER_DISPATCH_COUNT"
    $timerLastInterruptCount = Extract-IntValue -Text $out -Name "TIMER_LAST_INTERRUPT_COUNT"
    $timerLastWakeTick = Extract-IntValue -Text $out -Name "TIMER_LAST_WAKE_TICK"
    $timerQuantumOut = Extract-IntValue -Text $out -Name "TIMER_QUANTUM"
    $wakeQueueCount = Extract-IntValue -Text $out -Name "WAKE_QUEUE_COUNT"
    $timer0Id = Extract-IntValue -Text $out -Name "TIMER0_ID"
    $timer0TaskId = Extract-IntValue -Text $out -Name "TIMER0_TASK_ID"
    $timer0State = Extract-IntValue -Text $out -Name "TIMER0_STATE"
    $timer0Reason = Extract-IntValue -Text $out -Name "TIMER0_REASON"
    $timer0Flags = Extract-IntValue -Text $out -Name "TIMER0_FLAGS"
    $timer0PeriodTicks = Extract-IntValue -Text $out -Name "TIMER0_PERIOD_TICKS"
    $timer0NextFireTick = Extract-IntValue -Text $out -Name "TIMER0_NEXT_FIRE_TICK"
    $timer0FireCount = Extract-IntValue -Text $out -Name "TIMER0_FIRE_COUNT"
    $timer0LastFireTick = Extract-IntValue -Text $out -Name "TIMER0_LAST_FIRE_TICK"
    $firstFireCount = Extract-IntValue -Text $out -Name "FIRST_FIRE_COUNT"
    $firstDispatchCount = Extract-IntValue -Text $out -Name "FIRST_DISPATCH_COUNT"
    $firstWakeCount = Extract-IntValue -Text $out -Name "FIRST_WAKE_COUNT"
    $firstLastFireTick = Extract-IntValue -Text $out -Name "FIRST_LAST_FIRE_TICK"
    $secondFireCount = Extract-IntValue -Text $out -Name "SECOND_FIRE_COUNT"
    $secondDispatchCount = Extract-IntValue -Text $out -Name "SECOND_DISPATCH_COUNT"
    $secondWakeCount = Extract-IntValue -Text $out -Name "SECOND_WAKE_COUNT"
    $secondTick = Extract-IntValue -Text $out -Name "SECOND_TICK"
    $secondLastFireTick = Extract-IntValue -Text $out -Name "SECOND_LAST_FIRE_TICK"
    $secondNextFireTick = Extract-IntValue -Text $out -Name "SECOND_NEXT_FIRE_TICK"
    $wake0Seq = Extract-IntValue -Text $out -Name "WAKE0_SEQ"
    $wake0TaskId = Extract-IntValue -Text $out -Name "WAKE0_TASK_ID"
    $wake0TimerId = Extract-IntValue -Text $out -Name "WAKE0_TIMER_ID"
    $wake0Reason = Extract-IntValue -Text $out -Name "WAKE0_REASON"
    $wake0Vector = Extract-IntValue -Text $out -Name "WAKE0_VECTOR"
    $wake0Tick = Extract-IntValue -Text $out -Name "WAKE0_TICK"
    $wake1Seq = Extract-IntValue -Text $out -Name "WAKE1_SEQ"
    $wake1TaskId = Extract-IntValue -Text $out -Name "WAKE1_TASK_ID"
    $wake1TimerId = Extract-IntValue -Text $out -Name "WAKE1_TIMER_ID"
    $wake1Reason = Extract-IntValue -Text $out -Name "WAKE1_REASON"
    $wake1Vector = Extract-IntValue -Text $out -Name "WAKE1_VECTOR"
    $wake1Tick = Extract-IntValue -Text $out -Name "WAKE1_TICK"
    $wake2Seq = Extract-IntValue -Text $out -Name "WAKE2_SEQ"
    $wake2TaskId = Extract-IntValue -Text $out -Name "WAKE2_TASK_ID"
    $wake2TimerId = Extract-IntValue -Text $out -Name "WAKE2_TIMER_ID"
    $wake2Reason = Extract-IntValue -Text $out -Name "WAKE2_REASON"
    $wake2Vector = Extract-IntValue -Text $out -Name "WAKE2_VECTOR"
    $wake2Tick = Extract-IntValue -Text $out -Name "WAKE2_TICK"
    $interruptCount = Extract-IntValue -Text $out -Name "INTERRUPT_COUNT"
    $lastInterruptVector = Extract-IntValue -Text $out -Name "LAST_INTERRUPT_VECTOR"
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
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SCHEDULER_STATE_ADDR=0x$schedulerStateAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SCHEDULER_TASKS_ADDR=0x$schedulerTasksAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SCHEDULER_WAIT_KIND_ADDR=0x$schedulerWaitKindAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SCHEDULER_WAIT_INTERRUPT_VECTOR_ADDR=0x$schedulerWaitInterruptVectorAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SCHEDULER_WAIT_TIMEOUT_TICK_ADDR=0x$schedulerWaitTimeoutTickAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_STATE_ADDR=0x$timerStateAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_ENTRIES_ADDR=0x$timerEntriesAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE_QUEUE_COUNT_ADDR=0x$wakeQueueCountAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_INTERRUPT_STATE_ADDR=0x$interruptStateAddress"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_HIT_AFTER_PERIODIC_INTERRUPT=$hitAfterPeriodicInterrupt"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SCHED_TASK_COUNT=$schedulerTaskCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK0_STATE=$task0State"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK0_PRIORITY=$task0Priority"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK0_RUN_COUNT=$task0RunCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK0_BUDGET=$task0Budget"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK1_ID=$task1Id"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK1_STATE=$task1State"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK1_PRIORITY=$task1Priority"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK1_RUN_COUNT=$task1RunCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK1_BUDGET=$task1Budget"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TASK1_BUDGET_REMAINING=$task1BudgetRemaining"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAIT_KIND0=$waitKind0"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAIT_VECTOR0=$waitVector0"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAIT_TIMEOUT0=$waitTimeout0"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAIT_KIND1=$waitKind1"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAIT_VECTOR1=$waitVector1"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAIT_TIMEOUT1=$waitTimeout1"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_INTERRUPT_DEADLINE=$interruptDeadline"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_INTERRUPT_WAKE_TICK=$interruptWakeTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_ENABLED=$timerEnabled"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_LAST_WAKE_TICK=$timerLastWakeTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER_QUANTUM=$timerQuantumOut"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_ID=$timer0Id"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_TASK_ID=$timer0TaskId"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_STATE=$timer0State"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_REASON=$timer0Reason"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_FLAGS=$timer0Flags"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_PERIOD_TICKS=$timer0PeriodTicks"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_NEXT_FIRE_TICK=$timer0NextFireTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_FIRE_COUNT=$timer0FireCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMER0_LAST_FIRE_TICK=$timer0LastFireTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_FIRST_FIRE_COUNT=$firstFireCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_FIRST_DISPATCH_COUNT=$firstDispatchCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_FIRST_WAKE_COUNT=$firstWakeCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_FIRST_LAST_FIRE_TICK=$firstLastFireTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SECOND_FIRE_COUNT=$secondFireCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SECOND_DISPATCH_COUNT=$secondDispatchCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SECOND_WAKE_COUNT=$secondWakeCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SECOND_TICK=$secondTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SECOND_LAST_FIRE_TICK=$secondLastFireTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_SECOND_NEXT_FIRE_TICK=$secondNextFireTick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE1_SEQ=$wake1Seq"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE1_TASK_ID=$wake1TaskId"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE1_TIMER_ID=$wake1TimerId"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE1_REASON=$wake1Reason"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE1_VECTOR=$wake1Vector"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE1_TICK=$wake1Tick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE2_SEQ=$wake2Seq"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE2_TASK_ID=$wake2TaskId"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE2_TIMER_ID=$wake2TimerId"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE2_REASON=$wake2Reason"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE2_VECTOR=$wake2Vector"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_WAKE2_TICK=$wake2Tick"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_INTERRUPT_COUNT=$interruptCount"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and
    $hitAfterPeriodicInterrupt -and
    (-not $timedOut) -and
    $ack -eq 12 -and
    $lastOpcode -eq $timerCancelTaskOpcode -and
    $lastResult -eq 0 -and
    $mailboxOpcode -eq $timerCancelTaskOpcode -and
    $mailboxSeq -eq 12 -and
    $schedulerTaskCount -eq 2 -and
    $task0Id -eq 1 -and
    $task0State -eq $taskStateReady -and
    $task0Priority -eq $periodicTaskPriority -and
    $task0RunCount -eq 0 -and
    $task0Budget -eq $periodicTaskBudget -and
    $task0BudgetRemaining -eq $periodicTaskBudget -and
    $task1Id -eq 2 -and
    $task1State -eq $taskStateReady -and
    $task1Priority -eq $interruptTaskPriority -and
    $task1RunCount -eq 0 -and
    $task1Budget -eq $interruptTaskBudget -and
    $task1BudgetRemaining -eq $interruptTaskBudget -and
    $waitKind0 -eq $waitConditionNone -and
    $waitVector0 -eq 0 -and
    $waitTimeout0 -eq 0 -and
    $waitKind1 -eq $waitConditionNone -and
    $waitVector1 -eq 0 -and
    $waitTimeout1 -eq 0 -and
    $interruptDeadline -gt 0 -and
    $interruptWakeTick -gt 0 -and
    $interruptWakeTick -lt $interruptDeadline -and
    $timerEnabled -eq $timerStateEnabled -and
    $timerEntryCount -eq 0 -and
    $timerPendingWakeCount -eq 3 -and
    $timerDispatchCount -eq 2 -and
    $timerLastInterruptCount -eq 1 -and
    $timerQuantumOut -eq $timerQuantum -and
    $wakeQueueCount -eq 3 -and
    $timer0Id -eq 1 -and
    $timer0TaskId -eq 1 -and
    $timer0State -eq $timerEntryStateCanceled -and
    $timer0Reason -eq $wakeReasonTimer -and
    $timer0PeriodTicks -eq $periodicDelay -and
    $timer0FireCount -eq 2 -and
    $firstFireCount -eq 1 -and
    $firstDispatchCount -eq 1 -and
    $firstWakeCount -eq 1 -and
    $secondFireCount -eq 2 -and
    $secondDispatchCount -eq 2 -and
    $secondWakeCount -eq 3 -and
    $wake0Seq -eq 1 -and
    $wake0TaskId -eq 1 -and
    $wake0TimerId -eq 1 -and
    $wake0Reason -eq $wakeReasonTimer -and
    $wake0Vector -eq 0 -and
    $wake1Seq -eq 2 -and
    $wake1TaskId -eq 2 -and
    $wake1TimerId -eq 0 -and
    $wake1Reason -eq $wakeReasonInterrupt -and
    $wake1Vector -eq $interruptVector -and
    $wake2Seq -eq 3 -and
    $wake2TaskId -eq 1 -and
    $wake2TimerId -eq 1 -and
    $wake2Reason -eq $wakeReasonTimer -and
    $wake2Vector -eq 0 -and
    $interruptCount -eq 1 -and
    $lastInterruptVector -eq $interruptVector -and
    $timerLastWakeTick -eq $wake2Tick -and
    $timer0LastFireTick -eq $wake2Tick -and
    $firstLastFireTick -eq $wake0Tick -and
    $secondLastFireTick -eq $wake2Tick -and
    $ticks -ge ($interruptDeadline + $postDeadlineSlackTicks) -and
    $wake0Tick -lt $wake1Tick -and
    $wake1Tick -lt $wake2Tick -and
    $timer0NextFireTick -gt $timer0LastFireTick
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_PERIODIC_INTERRUPT_PROBE=fail"
if (Test-Path $gdbStdout) {
    Get-Content -Path $gdbStdout -Tail 120
}
if (Test-Path $gdbStderr) {
    Get-Content -Path $gdbStderr -Tail 120
}
if (Test-Path $qemuStderr) {
    Get-Content -Path $qemuStderr -Tail 120
}
exit 1



