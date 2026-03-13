param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$timerResetOpcode = 41
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskWaitInterruptOpcode = 57
$taskWaitForOpcode = 53
$timerDisableOpcode = 47
$timerEnableOpcode = 46
$triggerInterruptOpcode = 7

$interruptTaskBudget = 5
$interruptTaskPriority = 0
$timerTaskBudget = 6
$timerTaskPriority = 1
$interruptVector = 200
$timerDelay = 3
$pauseTicks = 4

$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonTimer = 1
$wakeReasonInterrupt = 2

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

$interruptStateLastInterruptVectorOffset = 2
$interruptStateInterruptCountOffset = 16

$timerEnabledOffset = 0
$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerDispatchCountOffset = 8
$timerLastDispatchTickOffset = 16
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
$wakeEventInterruptCountOffset = 24

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
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-timer-disable-interrupt-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-timer-disable-interrupt-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-timer-disable-interrupt-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-timer-disable-interrupt-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-timer-disable-interrupt-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-timer-disable-interrupt-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-timer-disable-interrupt-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-timer-disable-interrupt-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-timer-disable-interrupt-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-timer-disable-interrupt-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for timer-disable interrupt probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for timer-disable interrupt probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for timer-disable interrupt probe PVH artifact failed with exit code $LASTEXITCODE"
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
set `$interrupt_task_id = 0
set `$timer_task_id = 0
set `$pause_target_tick = 0
set `$after_interrupt_tick = 0
set `$after_interrupt_timer_count = 0
set `$after_interrupt_pending_wake_count = 0
set `$after_interrupt_wake_queue_count = 0
set `$after_interrupt_interrupt_task_state = 0
set `$after_interrupt_timer_task_state = 0
set `$paused_tick = 0
set `$paused_pending_wake_count = 0
set `$paused_wake_queue_count = 0
set `$paused_timer_entry_count = 0
set `$paused_timer_dispatch_count = 0
set `$paused_interrupt_task_state = 0
set `$paused_timer_task_state = 0
set `$final_tick = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptTaskPriority
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $timerTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timerTaskPriority
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset) != 0
    set `$interrupt_task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set `$timer_task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$interrupt_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 65535
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$timer_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timerDelay
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11 && *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset) == $taskStateWaiting && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == 0
    set `$after_interrupt_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$after_interrupt_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$after_interrupt_pending_wake_count = *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    set `$after_interrupt_wake_queue_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$after_interrupt_interrupt_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$after_interrupt_timer_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
    set `$pause_target_tick = `$after_interrupt_tick + $pauseTicks
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= `$pause_target_tick && *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset) == $taskStateWaiting && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == 0 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 0
    set `$paused_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$paused_pending_wake_count = *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    set `$paused_wake_queue_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$paused_timer_entry_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$paused_timer_dispatch_count = *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    set `$paused_interrupt_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$paused_timer_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerEnableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 13
  end
  continue
end
if `$stage == 13
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12 && *(unsigned int*)(0x$wakeQueueCountAddress) == 2 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset) == $taskStateReady && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) >= 1 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 1 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 0
    set `$final_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$stage = 14
  end
  continue
end
printf "AFTER_TIMER_DISABLE_INTERRUPT\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", `$final_tick
printf "TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "INTERRUPT_TASK_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
printf "INTERRUPT_TASK_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "INTERRUPT_TASK_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "INTERRUPT_TASK_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
printf "INTERRUPT_TASK_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetOffset)
printf "INTERRUPT_TASK_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
printf "TIMER_TASK_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset)
printf "TIMER_TASK_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
printf "TIMER_TASK_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskPriorityOffset)
printf "TIMER_TASK_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset)
printf "TIMER_TASK_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetOffset)
printf "TIMER_TASK_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetRemainingOffset)
printf "AFTER_INTERRUPT_TICK=%llu\n", `$after_interrupt_tick
printf "AFTER_INTERRUPT_TIMER_COUNT=%u\n", `$after_interrupt_timer_count
printf "AFTER_INTERRUPT_PENDING_WAKE_COUNT=%u\n", `$after_interrupt_pending_wake_count
printf "AFTER_INTERRUPT_WAKE_QUEUE_COUNT=%u\n", `$after_interrupt_wake_queue_count
printf "AFTER_INTERRUPT_INTERRUPT_TASK_STATE=%u\n", `$after_interrupt_interrupt_task_state
printf "AFTER_INTERRUPT_TIMER_TASK_STATE=%u\n", `$after_interrupt_timer_task_state
printf "PAUSED_TICK=%llu\n", `$paused_tick
printf "PAUSED_PENDING_WAKE_COUNT=%u\n", `$paused_pending_wake_count
printf "PAUSED_WAKE_QUEUE_COUNT=%u\n", `$paused_wake_queue_count
printf "PAUSED_TIMER_ENTRY_COUNT=%u\n", `$paused_timer_entry_count
printf "PAUSED_TIMER_DISPATCH_COUNT=%llu\n", `$paused_timer_dispatch_count
printf "PAUSED_INTERRUPT_TASK_STATE=%u\n", `$paused_interrupt_task_state
printf "PAUSED_TIMER_TASK_STATE=%u\n", `$paused_timer_task_state
printf "TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
printf "TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
printf "TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
printf "TIMER_LAST_DISPATCH_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastDispatchTickOffset)
printf "TIMER_LAST_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastInterruptCountOffset)
printf "TIMER_LAST_WAKE_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
printf "TIMER_QUANTUM=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
printf "TIMER0_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
printf "TIMER0_TASK_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTaskIdOffset)
printf "TIMER0_STATE=%u\n", *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset)
printf "TIMER0_REASON=%u\n", *(unsigned char*)(0x$timerEntriesAddress+$timerEntryReasonOffset)
printf "TIMER0_FLAGS=%u\n", *(unsigned short*)(0x$timerEntriesAddress+$timerEntryFlagsOffset)
printf "TIMER0_PERIOD_TICKS=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryPeriodTicksOffset)
printf "TIMER0_NEXT_FIRE_TICK=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryNextFireTickOffset)
printf "TIMER0_FIRE_COUNT=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset)
printf "TIMER0_LAST_FIRE_TICK=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryLastFireTickOffset)
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
printf "WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
printf "WAKE0_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventInterruptCountOffset)
printf "WAKE1_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventSeqOffset)
printf "WAKE1_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTaskIdOffset)
printf "WAKE1_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTimerIdOffset)
printf "WAKE1_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventReasonOffset)
printf "WAKE1_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventVectorOffset)
printf "WAKE1_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTickOffset)
printf "WAKE1_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventInterruptCountOffset)
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

foreach ($path in @($gdbStdout, $gdbStderr, $qemuStdout, $qemuStderr)) {
    if (Test-Path $path) {
        Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
    }
}

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

$gdbOutput = ""
$gdbError = ""
$hitStart = $false
$hitAfter = $false
if (Test-Path $gdbStdout) {
    $gdbOutput = [string](Get-Content -Path $gdbStdout -Raw)
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfter = $gdbOutput.Contains("AFTER_TIMER_DISABLE_INTERRUPT")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU timer-disable interrupt probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfter) {
    throw "Timer-disable interrupt probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskCount = Extract-IntValue -Text $gdbOutput -Name "TASK_COUNT"
$interruptTaskId = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_TASK_ID"
$interruptTaskState = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_TASK_STATE"
$interruptTaskPriorityOut = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_TASK_PRIORITY"
$interruptTaskRunCount = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_TASK_RUN_COUNT"
$interruptTaskBudgetOut = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_TASK_BUDGET"
$interruptTaskBudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_TASK_BUDGET_REMAINING"
$timerTaskId = Extract-IntValue -Text $gdbOutput -Name "TIMER_TASK_ID"
$timerTaskState = Extract-IntValue -Text $gdbOutput -Name "TIMER_TASK_STATE"
$timerTaskPriorityOut = Extract-IntValue -Text $gdbOutput -Name "TIMER_TASK_PRIORITY"
$timerTaskRunCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_TASK_RUN_COUNT"
$timerTaskBudgetOut = Extract-IntValue -Text $gdbOutput -Name "TIMER_TASK_BUDGET"
$timerTaskBudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "TIMER_TASK_BUDGET_REMAINING"
$afterInterruptTick = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_TICK"
$afterInterruptTimerCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_TIMER_COUNT"
$afterInterruptPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_PENDING_WAKE_COUNT"
$afterInterruptWakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_WAKE_QUEUE_COUNT"
$afterInterruptInterruptTaskState = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_INTERRUPT_TASK_STATE"
$afterInterruptTimerTaskState = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_TIMER_TASK_STATE"
$pausedTick = Extract-IntValue -Text $gdbOutput -Name "PAUSED_TICK"
$pausedPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "PAUSED_PENDING_WAKE_COUNT"
$pausedWakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "PAUSED_WAKE_QUEUE_COUNT"
$pausedTimerEntryCount = Extract-IntValue -Text $gdbOutput -Name "PAUSED_TIMER_ENTRY_COUNT"
$pausedTimerDispatchCount = Extract-IntValue -Text $gdbOutput -Name "PAUSED_TIMER_DISPATCH_COUNT"
$pausedInterruptTaskState = Extract-IntValue -Text $gdbOutput -Name "PAUSED_INTERRUPT_TASK_STATE"
$pausedTimerTaskState = Extract-IntValue -Text $gdbOutput -Name "PAUSED_TIMER_TASK_STATE"
$timerEnabled = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENABLED"
$timerEntryCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENTRY_COUNT"
$timerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_PENDING_WAKE_COUNT"
$timerDispatchCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_DISPATCH_COUNT"
$timerLastDispatchTick = Extract-IntValue -Text $gdbOutput -Name "TIMER_LAST_DISPATCH_TICK"
$timerLastInterruptCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_LAST_INTERRUPT_COUNT"
$timerLastWakeTick = Extract-IntValue -Text $gdbOutput -Name "TIMER_LAST_WAKE_TICK"
$timerQuantum = Extract-IntValue -Text $gdbOutput -Name "TIMER_QUANTUM"
$timer0Id = Extract-IntValue -Text $gdbOutput -Name "TIMER0_ID"
$timer0TaskId = Extract-IntValue -Text $gdbOutput -Name "TIMER0_TASK_ID"
$timer0State = Extract-IntValue -Text $gdbOutput -Name "TIMER0_STATE"
$timer0Reason = Extract-IntValue -Text $gdbOutput -Name "TIMER0_REASON"
$timer0Flags = Extract-IntValue -Text $gdbOutput -Name "TIMER0_FLAGS"
$timer0PeriodTicks = Extract-IntValue -Text $gdbOutput -Name "TIMER0_PERIOD_TICKS"
$timer0NextFireTick = Extract-IntValue -Text $gdbOutput -Name "TIMER0_NEXT_FIRE_TICK"
$timer0FireCount = Extract-IntValue -Text $gdbOutput -Name "TIMER0_FIRE_COUNT"
$timer0LastFireTick = Extract-IntValue -Text $gdbOutput -Name "TIMER0_LAST_FIRE_TICK"
$wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
$wake0Seq = Extract-IntValue -Text $gdbOutput -Name "WAKE0_SEQ"
$wake0TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TASK_ID"
$wake0TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TIMER_ID"
$wake0Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE0_REASON"
$wake0Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE0_VECTOR"
$wake0Tick = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TICK"
$wake0InterruptCount = Extract-IntValue -Text $gdbOutput -Name "WAKE0_INTERRUPT_COUNT"
$wake1Seq = Extract-IntValue -Text $gdbOutput -Name "WAKE1_SEQ"
$wake1TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE1_TASK_ID"
$wake1TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE1_TIMER_ID"
$wake1Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE1_REASON"
$wake1Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE1_VECTOR"
$wake1Tick = Extract-IntValue -Text $gdbOutput -Name "WAKE1_TICK"
$wake1InterruptCount = Extract-IntValue -Text $gdbOutput -Name "WAKE1_INTERRUPT_COUNT"
$interruptCount = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_COUNT"
$lastInterruptVector = Extract-IntValue -Text $gdbOutput -Name "LAST_INTERRUPT_VECTOR"

if ($ack -ne 12) { throw "Expected ACK=12, got $ack" }
if ($lastOpcode -ne $timerEnableOpcode) { throw "Expected LAST_OPCODE=$timerEnableOpcode, got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0, got $lastResult" }
if ($ticks -lt ($pauseTicks + 6)) { throw "Expected TICKS >= $($pauseTicks + 6), got $ticks" }
if ($taskCount -ne 2) { throw "Expected TASK_COUNT=2, got $taskCount" }
if ($interruptTaskId -le 0) { throw "Expected INTERRUPT_TASK_ID > 0, got $interruptTaskId" }
if ($timerTaskId -le $interruptTaskId) { throw "Expected TIMER_TASK_ID > INTERRUPT_TASK_ID, got interrupt=$interruptTaskId timer=$timerTaskId" }
if ($interruptTaskState -ne $taskStateReady) { throw "Expected INTERRUPT_TASK_STATE=$taskStateReady, got $interruptTaskState" }
if ($timerTaskState -ne $taskStateReady) { throw "Expected TIMER_TASK_STATE=$taskStateReady, got $timerTaskState" }
if ($interruptTaskPriorityOut -ne $interruptTaskPriority) { throw "Expected INTERRUPT_TASK_PRIORITY=$interruptTaskPriority, got $interruptTaskPriorityOut" }
if ($timerTaskPriorityOut -ne $timerTaskPriority) { throw "Expected TIMER_TASK_PRIORITY=$timerTaskPriority, got $timerTaskPriorityOut" }
if ($interruptTaskRunCount -ne 0) { throw "Expected INTERRUPT_TASK_RUN_COUNT=0, got $interruptTaskRunCount" }
if ($timerTaskRunCount -ne 0) { throw "Expected TIMER_TASK_RUN_COUNT=0, got $timerTaskRunCount" }
if ($interruptTaskBudgetOut -ne $interruptTaskBudget) { throw "Expected INTERRUPT_TASK_BUDGET=$interruptTaskBudget, got $interruptTaskBudgetOut" }
if ($timerTaskBudgetOut -ne $timerTaskBudget) { throw "Expected TIMER_TASK_BUDGET=$timerTaskBudget, got $timerTaskBudgetOut" }
if ($interruptTaskBudgetRemaining -ne $interruptTaskBudget) { throw "Expected INTERRUPT_TASK_BUDGET_REMAINING=$interruptTaskBudget, got $interruptTaskBudgetRemaining" }
if ($timerTaskBudgetRemaining -ne $timerTaskBudget) { throw "Expected TIMER_TASK_BUDGET_REMAINING=$timerTaskBudget, got $timerTaskBudgetRemaining" }
if ($afterInterruptTick -le 0) { throw "Expected AFTER_INTERRUPT_TICK > 0, got $afterInterruptTick" }
if ($afterInterruptTimerCount -ne 1) { throw "Expected AFTER_INTERRUPT_TIMER_COUNT=1, got $afterInterruptTimerCount" }
if ($afterInterruptPendingWakeCount -ne 1) { throw "Expected AFTER_INTERRUPT_PENDING_WAKE_COUNT=1, got $afterInterruptPendingWakeCount" }
if ($afterInterruptWakeQueueCount -ne 1) { throw "Expected AFTER_INTERRUPT_WAKE_QUEUE_COUNT=1, got $afterInterruptWakeQueueCount" }
if ($afterInterruptInterruptTaskState -ne $taskStateReady) { throw "Expected AFTER_INTERRUPT_INTERRUPT_TASK_STATE=$taskStateReady, got $afterInterruptInterruptTaskState" }
if ($afterInterruptTimerTaskState -ne $taskStateWaiting) { throw "Expected AFTER_INTERRUPT_TIMER_TASK_STATE=$taskStateWaiting, got $afterInterruptTimerTaskState" }
if ($pausedTick -lt ($afterInterruptTick + $pauseTicks)) { throw "Expected PAUSED_TICK >= AFTER_INTERRUPT_TICK + $pauseTicks, got AFTER_INTERRUPT_TICK=$afterInterruptTick PAUSED_TICK=$pausedTick" }
if ($pausedPendingWakeCount -ne 1) { throw "Expected PAUSED_PENDING_WAKE_COUNT=1, got $pausedPendingWakeCount" }
if ($pausedWakeQueueCount -ne 1) { throw "Expected PAUSED_WAKE_QUEUE_COUNT=1, got $pausedWakeQueueCount" }
if ($pausedTimerEntryCount -ne 1) { throw "Expected PAUSED_TIMER_ENTRY_COUNT=1, got $pausedTimerEntryCount" }
if ($pausedTimerDispatchCount -ne 0) { throw "Expected PAUSED_TIMER_DISPATCH_COUNT=0, got $pausedTimerDispatchCount" }
if ($pausedInterruptTaskState -ne $taskStateReady) { throw "Expected PAUSED_INTERRUPT_TASK_STATE=$taskStateReady, got $pausedInterruptTaskState" }
if ($pausedTimerTaskState -ne $taskStateWaiting) { throw "Expected PAUSED_TIMER_TASK_STATE=$taskStateWaiting, got $pausedTimerTaskState" }
if ($timerEnabled -ne 1) { throw "Expected TIMER_ENABLED=1, got $timerEnabled" }
if ($timerEntryCount -ne 0) { throw "Expected TIMER_ENTRY_COUNT=0 after one-shot fire, got $timerEntryCount" }
if ($timerPendingWakeCount -ne 2) { throw "Expected TIMER_PENDING_WAKE_COUNT=2, got $timerPendingWakeCount" }
if ($timerDispatchCount -lt 1) { throw "Expected TIMER_DISPATCH_COUNT >= 1, got $timerDispatchCount" }
if ($timerLastDispatchTick -ne $timer0LastFireTick) { throw "Expected TIMER_LAST_DISPATCH_TICK=$timer0LastFireTick, got $timerLastDispatchTick" }
if ($timerLastInterruptCount -lt 1) { throw "Expected TIMER_LAST_INTERRUPT_COUNT >= 1, got $timerLastInterruptCount" }
if ($timerLastWakeTick -ne $wake1Tick) { throw "Expected TIMER_LAST_WAKE_TICK=$wake1Tick, got $timerLastWakeTick" }
if ($timerQuantum -ne 1) { throw "Expected TIMER_QUANTUM=1, got $timerQuantum" }
if ($timer0Id -ne 1) { throw "Expected TIMER0_ID=1, got $timer0Id" }
if ($timer0TaskId -ne $timerTaskId) { throw "Expected TIMER0_TASK_ID=$timerTaskId, got $timer0TaskId" }
if ($timer0State -ne 2) { throw "Expected TIMER0_STATE=2, got $timer0State" }
if ($timer0Reason -ne $wakeReasonTimer) { throw "Expected TIMER0_REASON=$wakeReasonTimer, got $timer0Reason" }
if ($timer0Flags -ne 0) { throw "Expected TIMER0_FLAGS=0, got $timer0Flags" }
if ($timer0PeriodTicks -ne 0) { throw "Expected TIMER0_PERIOD_TICKS=0, got $timer0PeriodTicks" }
if ($timer0NextFireTick -lt $afterInterruptTick) { throw "Expected TIMER0_NEXT_FIRE_TICK >= AFTER_INTERRUPT_TICK, got TIMER0_NEXT_FIRE_TICK=$timer0NextFireTick AFTER_INTERRUPT_TICK=$afterInterruptTick" }
if ($timer0FireCount -ne 1) { throw "Expected TIMER0_FIRE_COUNT=1, got $timer0FireCount" }
if ($timer0LastFireTick -lt $pausedTick) { throw "Expected TIMER0_LAST_FIRE_TICK >= PAUSED_TICK, got TIMER0_LAST_FIRE_TICK=$timer0LastFireTick PAUSED_TICK=$pausedTick" }
if ($wakeQueueCount -ne 2) { throw "Expected WAKE_QUEUE_COUNT=2, got $wakeQueueCount" }
if ($wake0Seq -ne 1) { throw "Expected WAKE0_SEQ=1, got $wake0Seq" }
if ($wake0TaskId -ne $interruptTaskId) { throw "Expected WAKE0_TASK_ID=$interruptTaskId, got $wake0TaskId" }
if ($wake0TimerId -ne 0) { throw "Expected WAKE0_TIMER_ID=0, got $wake0TimerId" }
if ($wake0Reason -ne $wakeReasonInterrupt) { throw "Expected WAKE0_REASON=$wakeReasonInterrupt, got $wake0Reason" }
if ($wake0Vector -ne $interruptVector) { throw "Expected WAKE0_VECTOR=$interruptVector, got $wake0Vector" }
if ($wake0Tick -gt $afterInterruptTick) { throw "Expected WAKE0_TICK <= AFTER_INTERRUPT_TICK, got WAKE0_TICK=$wake0Tick AFTER_INTERRUPT_TICK=$afterInterruptTick" }
if ($wake0InterruptCount -lt 1) { throw "Expected WAKE0_INTERRUPT_COUNT >= 1, got $wake0InterruptCount" }
if ($wake1Seq -ne 2) { throw "Expected WAKE1_SEQ=2, got $wake1Seq" }
if ($wake1TaskId -ne $timerTaskId) { throw "Expected WAKE1_TASK_ID=$timerTaskId, got $wake1TaskId" }
if ($wake1TimerId -ne $timer0Id) { throw "Expected WAKE1_TIMER_ID=$timer0Id, got $wake1TimerId" }
if ($wake1Reason -ne $wakeReasonTimer) { throw "Expected WAKE1_REASON=$wakeReasonTimer, got $wake1Reason" }
if ($wake1Vector -ne 0) { throw "Expected WAKE1_VECTOR=0, got $wake1Vector" }
if ($wake1Tick -ne $timer0LastFireTick) { throw "Expected WAKE1_TICK=$timer0LastFireTick, got $wake1Tick" }
if ($wake1InterruptCount -ne $wake0InterruptCount) { throw "Expected WAKE1_INTERRUPT_COUNT=$wake0InterruptCount, got $wake1InterruptCount" }
if ($interruptCount -lt 1) { throw "Expected INTERRUPT_COUNT >= 1, got $interruptCount" }
if ($lastInterruptVector -ne $interruptVector) { throw "Expected LAST_INTERRUPT_VECTOR=$interruptVector, got $lastInterruptVector" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PROBE=pass"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_ACK=$ack"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_TASK_COUNT=$taskCount"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_AFTER_INTERRUPT_TICK=$afterInterruptTick"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_AFTER_INTERRUPT_WAKE_QUEUE_COUNT=$afterInterruptWakeQueueCount"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_AFTER_INTERRUPT_INTERRUPT_TASK_STATE=$afterInterruptInterruptTaskState"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_AFTER_INTERRUPT_TIMER_TASK_STATE=$afterInterruptTimerTaskState"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PAUSED_TICK=$pausedTick"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PAUSED_WAKE_QUEUE_COUNT=$pausedWakeQueueCount"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PAUSED_TIMER_ENTRY_COUNT=$pausedTimerEntryCount"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PAUSED_TIMER_DISPATCH_COUNT=$pausedTimerDispatchCount"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PAUSED_INTERRUPT_TASK_STATE=$pausedInterruptTaskState"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_PAUSED_TIMER_TASK_STATE=$pausedTimerTaskState"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_TIMER_LAST_FIRE_TICK=$timer0LastFireTick"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_WAKE1_REASON=$wake1Reason"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_INTERRUPT_INTERRUPT_COUNT=$interruptCount"
Write-Output "INTERRUPT_TASK_ID=$interruptTaskId"
Write-Output "TIMER_TASK_ID=$timerTaskId"
Write-Output "AFTER_INTERRUPT_TICK=$afterInterruptTick"
Write-Output "AFTER_INTERRUPT_TIMER_COUNT=$afterInterruptTimerCount"
Write-Output "AFTER_INTERRUPT_PENDING_WAKE_COUNT=$afterInterruptPendingWakeCount"
Write-Output "AFTER_INTERRUPT_WAKE_QUEUE_COUNT=$afterInterruptWakeQueueCount"
Write-Output "AFTER_INTERRUPT_INTERRUPT_TASK_STATE=$afterInterruptInterruptTaskState"
Write-Output "AFTER_INTERRUPT_TIMER_TASK_STATE=$afterInterruptTimerTaskState"
Write-Output "PAUSED_TICK=$pausedTick"
Write-Output "PAUSED_PENDING_WAKE_COUNT=$pausedPendingWakeCount"
Write-Output "PAUSED_WAKE_QUEUE_COUNT=$pausedWakeQueueCount"
Write-Output "PAUSED_TIMER_ENTRY_COUNT=$pausedTimerEntryCount"
Write-Output "PAUSED_TIMER_DISPATCH_COUNT=$pausedTimerDispatchCount"
Write-Output "PAUSED_INTERRUPT_TASK_STATE=$pausedInterruptTaskState"
Write-Output "PAUSED_TIMER_TASK_STATE=$pausedTimerTaskState"
Write-Output "TIMER_ENABLED=$timerEnabled"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "TIMER0_ID=$timer0Id"
Write-Output "TIMER0_TASK_ID=$timer0TaskId"
Write-Output "TIMER0_LAST_FIRE_TICK=$timer0LastFireTick"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_TASK_ID=$wake0TaskId"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "WAKE0_TICK=$wake0Tick"
Write-Output "WAKE0_INTERRUPT_COUNT=$wake0InterruptCount"
Write-Output "WAKE1_TASK_ID=$wake1TaskId"
Write-Output "WAKE1_TIMER_ID=$wake1TimerId"
Write-Output "WAKE1_REASON=$wake1Reason"
Write-Output "WAKE1_VECTOR=$wake1Vector"
Write-Output "WAKE1_TICK=$wake1Tick"
Write-Output "WAKE1_INTERRUPT_COUNT=$wake1InterruptCount"
Write-Output "INTERRUPT_COUNT=$interruptCount"
Write-Output "LAST_INTERRUPT_VECTOR=$lastInterruptVector"

