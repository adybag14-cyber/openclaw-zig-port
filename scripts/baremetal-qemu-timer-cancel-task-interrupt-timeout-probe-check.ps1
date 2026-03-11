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
$taskCreateOpcode = 27
$taskWaitInterruptForOpcode = 58
$timerCancelTaskOpcode = 52
$triggerInterruptOpcode = 7

$taskBudget = 5
$taskPriority = 0
$timeoutTicks = 5
$postWakeSlackTicks = 8
$interruptVector = 200

$waitConditionNone = 0
$waitConditionInterruptAny = 3
$taskStateReady = 1
$taskStateWaiting = 6
$timerStateEnabled = 1
$wakeReasonManual = 3
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

$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetOffset = 12
$taskBudgetRemainingOffset = 16

$timerEnabledOffset = 0
$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerNextTimerIdOffset = 4
$timerDispatchCountOffset = 8
$timerLastInterruptCountOffset = 24
$timerLastWakeTickOffset = 32

$interruptStateLastInterruptVectorOffset = 2
$interruptStateInterruptCountOffset = 16

$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventTimerIdOffset = 8
$wakeEventReasonOffset = 12
$wakeEventVectorOffset = 13
$wakeEventTickOffset = 16
$timerEntryFireCountOffset = 24
$timerEntryLastFireTickOffset = 32

$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventTimerIdOffset = 8
$wakeEventReasonOffset = 12
$wakeEventVectorOffset = 13
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
    Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-timer-cancel-task-interrupt-timeout-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-timer-cancel-task-interrupt-timeout-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-timer-cancel-task-interrupt-timeout-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-timer-cancel-task-interrupt-timeout-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-timer-cancel-task-interrupt-timeout-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-timer-cancel-task-interrupt-timeout-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-timer-cancel-task-interrupt-timeout-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-timer-cancel-task-interrupt-timeout-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-timer-cancel-task-interrupt-timeout-probe.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null

    @"
pub const qemu_smoke: bool = false;
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
        --name "openclaw-zig-baremetal-main-timer-cancel-task-interrupt-timeout-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for task-resume interrupt-timeout probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for task-resume interrupt-timeout probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for task-resume interrupt-timeout probe PVH artifact failed with exit code $LASTEXITCODE"
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
set `$armed_tick = 0
set `$armed_task0_state = 0
set `$armed_wait_kind0 = 0
set `$armed_wait_vector0 = 0
set `$armed_wait_timeout0 = 0
set `$armed_wake_queue_count = 0
set `$cancel_tick = 0
set `$cancel_task0_state = 0
set `$cancel_wait_kind0 = 0
set `$cancel_wait_vector0 = 0
set `$cancel_wait_timeout0 = 0
set `$cancel_timer_entry_count = 0
set `$cancel_timer_pending_wake_count = 0
set `$cancel_wake_queue_count = 0
set `$post_wake_tick = 0
set `$post_idle_tick = 0
set `$post_idle_task0_state = 0
set `$post_idle_wait_kind0 = 0
set `$post_idle_wait_vector0 = 0
set `$post_idle_wait_timeout0 = 0
set `$post_idle_timer_entry_count = 0
set `$post_idle_timer_pending_wake_count = 0
set `$post_idle_wake_queue_count = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timeoutTicks
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionInterruptAny && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress) > *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set `$armed_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$armed_task0_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$armed_wait_kind0 = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set `$armed_wait_vector0 = *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
    set `$armed_wait_timeout0 = *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
    set `$armed_wake_queue_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerCancelTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned int*)(0x$wakeQueueCountAddress) == 0 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionInterruptAny && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress) == 0
    set `$cancel_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$cancel_task0_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$cancel_wait_kind0 = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set `$cancel_wait_vector0 = *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
    set `$cancel_wait_timeout0 = *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
    set `$cancel_timer_entry_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$cancel_timer_pending_wake_count = *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    set `$cancel_wake_queue_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned int*)(0x$wakeQueueCountAddress) >= 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionNone && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress) == 0 && *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset) == $interruptVector
    set `$post_wake_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= `$post_wake_tick + $postWakeSlackTicks && *(unsigned int*)(0x$wakeQueueCountAddress) == 1
    set `$post_idle_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$post_idle_task0_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$post_idle_wait_kind0 = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set `$post_idle_wait_vector0 = *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
    set `$post_idle_wait_timeout0 = *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
    set `$post_idle_timer_entry_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$post_idle_timer_pending_wake_count = *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    set `$post_idle_wake_queue_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$stage = 10
  end
  continue
end
printf "AFTER_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT\n"
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
printf "ARMED_TICK=%llu\n", `$armed_tick
printf "ARMED_TASK0_STATE=%u\n", `$armed_task0_state
printf "ARMED_WAIT_KIND0=%u\n", `$armed_wait_kind0
printf "ARMED_WAIT_VECTOR0=%u\n", `$armed_wait_vector0
printf "ARMED_WAIT_TIMEOUT0=%llu\n", `$armed_wait_timeout0
printf "ARMED_WAKE_QUEUE_COUNT=%u\n", `$armed_wake_queue_count
printf "CANCEL_TICK=%llu\n", `$cancel_tick
printf "CANCEL_TASK0_STATE=%u\n", `$cancel_task0_state
printf "CANCEL_WAIT_KIND0=%u\n", `$cancel_wait_kind0
printf "CANCEL_WAIT_VECTOR0=%u\n", `$cancel_wait_vector0
printf "CANCEL_WAIT_TIMEOUT0=%llu\n", `$cancel_wait_timeout0
printf "CANCEL_TIMER_ENTRY_COUNT=%u\n", `$cancel_timer_entry_count
printf "CANCEL_TIMER_PENDING_WAKE_COUNT=%u\n", `$cancel_timer_pending_wake_count
printf "CANCEL_WAKE_QUEUE_COUNT=%u\n", `$cancel_wake_queue_count
printf "POST_IDLE_TICK=%llu\n", `$post_idle_tick
printf "POST_IDLE_TASK0_STATE=%u\n", `$post_idle_task0_state
printf "POST_IDLE_WAIT_KIND0=%u\n", `$post_idle_wait_kind0
printf "POST_IDLE_WAIT_VECTOR0=%u\n", `$post_idle_wait_vector0
printf "POST_IDLE_WAIT_TIMEOUT0=%llu\n", `$post_idle_wait_timeout0
printf "POST_IDLE_TIMER_ENTRY_COUNT=%u\n", `$post_idle_timer_entry_count
printf "POST_IDLE_TIMER_PENDING_WAKE_COUNT=%u\n", `$post_idle_timer_pending_wake_count
printf "POST_IDLE_WAKE_QUEUE_COUNT=%u\n", `$post_idle_wake_queue_count
printf "WAIT_KIND0=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress)
printf "WAIT_VECTOR0=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
printf "WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
printf "TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
printf "TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
printf "TIMER_NEXT_TIMER_ID=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
printf "TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
printf "TIMER_LAST_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastInterruptCountOffset)
printf "TIMER_LAST_WAKE_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
printf "WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
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
$hitAfterTaskResumeInterruptTimeout = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$schedTaskCount = $null
$task0Id = $null
$task0State = $null
$task0Priority = $null
$task0RunCount = $null
$task0Budget = $null
$task0BudgetRemaining = $null
$armedTick = $null
$armedTask0State = $null
$armedWaitKind0 = $null
$armedWaitVector0 = $null
$armedWaitTimeout0 = $null
$armedWakeQueueCount = $null
$cancelTick = $null
$cancelTask0State = $null
$cancelWaitKind0 = $null
$cancelWaitVector0 = $null
$cancelWaitTimeout0 = $null
$cancelTimerEntryCount = $null
$cancelTimerPendingWakeCount = $null
$cancelWakeQueueCount = $null
$postIdleTick = $null
$postIdleTask0State = $null
$postIdleWaitKind0 = $null
$postIdleWaitVector0 = $null
$postIdleWaitTimeout0 = $null
$postIdleTimerEntryCount = $null
$postIdleTimerPendingWakeCount = $null
$postIdleWakeQueueCount = $null
$waitKind0 = $null
$waitVector0 = $null
$waitTimeout0 = $null
$timerEnabled = $null
$timerEntryCount = $null
$timerPendingWakeCount = $null
$timerNextTimerId = $null
$timerDispatchCount = $null
$timerLastInterruptCount = $null
$timerLastWakeTick = $null
$wakeQueueCount = $null
$wake0Seq = $null
$wake0TaskId = $null
$wake0TimerId = $null
$wake0Reason = $null
$wake0Vector = $null
$wake0Tick = $null
$interruptCount = $null
$lastInterruptVector = $null

if (Test-Path $gdbStdout) {
    $gdbOutput = [string](Get-Content -Path $gdbStdout -Raw)
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfterTaskResumeInterruptTimeout = $gdbOutput.Contains("AFTER_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT")
    $ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_SEQ"
    $schedTaskCount = Extract-IntValue -Text $gdbOutput -Name "SCHED_TASK_COUNT"
    $task0Id = Extract-IntValue -Text $gdbOutput -Name "TASK0_ID"
    $task0State = Extract-IntValue -Text $gdbOutput -Name "TASK0_STATE"
    $task0Priority = Extract-IntValue -Text $gdbOutput -Name "TASK0_PRIORITY"
    $task0RunCount = Extract-IntValue -Text $gdbOutput -Name "TASK0_RUN_COUNT"
    $task0Budget = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET"
    $task0BudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET_REMAINING"
    $armedTick = Extract-IntValue -Text $gdbOutput -Name "ARMED_TICK"
    $armedTask0State = Extract-IntValue -Text $gdbOutput -Name "ARMED_TASK0_STATE"
    $armedWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "ARMED_WAIT_KIND0"
    $armedWaitVector0 = Extract-IntValue -Text $gdbOutput -Name "ARMED_WAIT_VECTOR0"
    $armedWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "ARMED_WAIT_TIMEOUT0"
    $armedWakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "ARMED_WAKE_QUEUE_COUNT"
    $cancelTick = Extract-IntValue -Text $gdbOutput -Name "CANCEL_TICK"
    $cancelTask0State = Extract-IntValue -Text $gdbOutput -Name "CANCEL_TASK0_STATE"
    $cancelWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "CANCEL_WAIT_KIND0"
    $cancelWaitVector0 = Extract-IntValue -Text $gdbOutput -Name "CANCEL_WAIT_VECTOR0"
    $cancelWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "CANCEL_WAIT_TIMEOUT0"
    $cancelTimerEntryCount = Extract-IntValue -Text $gdbOutput -Name "CANCEL_TIMER_ENTRY_COUNT"
    $cancelTimerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "CANCEL_TIMER_PENDING_WAKE_COUNT"
    $cancelWakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "CANCEL_WAKE_QUEUE_COUNT"
    $postIdleTick = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_TICK"
    $postIdleTask0State = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_TASK0_STATE"
    $postIdleWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_WAIT_KIND0"
    $postIdleWaitVector0 = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_WAIT_VECTOR0"
    $postIdleWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_WAIT_TIMEOUT0"
    $postIdleTimerEntryCount = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_TIMER_ENTRY_COUNT"
    $postIdleTimerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_TIMER_PENDING_WAKE_COUNT"
    $postIdleWakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_WAKE_QUEUE_COUNT"
    $waitKind0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_KIND0"
    $waitVector0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_VECTOR0"
    $waitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_TIMEOUT0"
    $timerEnabled = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENABLED"
    $timerEntryCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENTRY_COUNT"
    $timerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_PENDING_WAKE_COUNT"
    $timerNextTimerId = Extract-IntValue -Text $gdbOutput -Name "TIMER_NEXT_TIMER_ID"
    $timerDispatchCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_DISPATCH_COUNT"
    $timerLastInterruptCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_LAST_INTERRUPT_COUNT"
    $timerLastWakeTick = Extract-IntValue -Text $gdbOutput -Name "TIMER_LAST_WAKE_TICK"
    $wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
    $wake0Seq = Extract-IntValue -Text $gdbOutput -Name "WAKE0_SEQ"
    $wake0TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TASK_ID"
    $wake0TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TIMER_ID"
    $wake0Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE0_REASON"
    $wake0Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE0_VECTOR"
    $wake0Tick = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TICK"
    $interruptCount = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_COUNT"
    $lastInterruptVector = Extract-IntValue -Text $gdbOutput -Name "LAST_INTERRUPT_VECTOR"
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
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_SCHEDULER_STATE_ADDR=0x$schedulerStateAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_SCHEDULER_TASKS_ADDR=0x$schedulerTasksAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_SCHEDULER_WAIT_KIND_ADDR=0x$schedulerWaitKindAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_SCHEDULER_WAIT_INTERRUPT_VECTOR_ADDR=0x$schedulerWaitInterruptVectorAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_SCHEDULER_WAIT_TIMEOUT_TICK_ADDR=0x$schedulerWaitTimeoutTickAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_STATE_ADDR=0x$timerStateAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE_QUEUE_COUNT_ADDR=0x$wakeQueueCountAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_INTERRUPT_STATE_ADDR=0x$interruptStateAddress"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_HIT_AFTER=$hitAfterTaskResumeInterruptTimeout"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TASK0_STATE=$task0State"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TASK0_PRIORITY=$task0Priority"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TASK0_RUN_COUNT=$task0RunCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TASK0_BUDGET=$task0Budget"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_TICK=$armedTick"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_TASK0_STATE=$armedTask0State"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAIT_KIND0=$armedWaitKind0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAIT_VECTOR0=$armedWaitVector0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAIT_TIMEOUT0=$armedWaitTimeout0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_ARMED_WAKE_QUEUE_COUNT=$armedWakeQueueCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_TICK=$cancelTick"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_TASK0_STATE=$cancelTask0State"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAIT_KIND0=$cancelWaitKind0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAIT_VECTOR0=$cancelWaitVector0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAIT_TIMEOUT0=$cancelWaitTimeout0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_TIMER_ENTRY_COUNT=$cancelTimerEntryCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_TIMER_PENDING_WAKE_COUNT=$cancelTimerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_CANCEL_WAKE_QUEUE_COUNT=$cancelWakeQueueCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TICK=$postIdleTick"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TASK0_STATE=$postIdleTask0State"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_KIND0=$postIdleWaitKind0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_VECTOR0=$postIdleWaitVector0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAIT_TIMEOUT0=$postIdleWaitTimeout0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TIMER_ENTRY_COUNT=$postIdleTimerEntryCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_TIMER_PENDING_WAKE_COUNT=$postIdleTimerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_POST_IDLE_WAKE_QUEUE_COUNT=$postIdleWakeQueueCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAIT_KIND0=$waitKind0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAIT_VECTOR0=$waitVector0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAIT_TIMEOUT0=$waitTimeout0"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_ENABLED=$timerEnabled"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_NEXT_TIMER_ID=$timerNextTimerId"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMER_LAST_WAKE_TICK=$timerLastWakeTick"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_INTERRUPT_COUNT=$interruptCount"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE_TIMED_OUT=$timedOut"

$probePassed = $hitStart -and
    $hitAfterTaskResumeInterruptTimeout -and
    (-not $timedOut) -and
    ($ack -eq 8) -and
    ($lastOpcode -eq $triggerInterruptOpcode) -and
    ($lastResult -eq 0) -and
    ($mailboxOpcode -eq $triggerInterruptOpcode) -and
    ($mailboxSeq -eq 8) -and
    ($schedTaskCount -eq 1) -and
    ($task0Id -eq 1) -and
    ($task0State -eq $taskStateReady) -and
    ($task0Priority -eq $taskPriority) -and
    ($task0RunCount -eq 0) -and
    ($task0Budget -eq $taskBudget) -and
    ($task0BudgetRemaining -eq $taskBudget) -and
    ($postIdleTask0State -eq $taskStateReady) -and
    ($postIdleWaitKind0 -eq $waitConditionNone) -and
    ($postIdleWaitVector0 -eq 0) -and
    ($postIdleWaitTimeout0 -eq 0) -and
    ($timerEnabled -eq $timerStateEnabled) -and
    ($postIdleTimerEntryCount -eq 0) -and
    ($postIdleTimerPendingWakeCount -eq 1) -and
    ($timerNextTimerId -eq 1) -and
    ($timerDispatchCount -eq 0) -and
    ($timerLastInterruptCount -eq 1) -and
    ($postIdleWakeQueueCount -eq 1) -and
    ($wake0Seq -eq 1) -and
    ($wake0TaskId -eq 1) -and
    ($wake0TimerId -eq 0) -and
    ($wake0Reason -eq $wakeReasonInterrupt) -and
    ($wake0Vector -eq $interruptVector) -and
    ($interruptCount -eq 1) -and
    ($lastInterruptVector -eq $interruptVector) -and
    ($timerLastWakeTick -eq $wake0Tick) -and
    ($ticks -ge ($wake0Tick + $postWakeSlackTicks))

Write-Output "BAREMETAL_QEMU_TIMER_CANCEL_TASK_INTERRUPT_TIMEOUT_PROBE=$($(if ($probePassed) { 'pass' } else { 'fail' }))"

if (-not $probePassed) {
    if (Test-Path $gdbStderr) {
        Get-Content -Path $gdbStderr | Write-Error
    }
    exit 1
}


