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
$timerDisableOpcode = 47
$timerEnableOpcode = 46
$triggerInterruptOpcode = 7

$taskBudget = 5
$taskPriority = 0
$timeoutTicks = 5
$interruptVector = 31
$postWakeSlackTicks = 8

$waitConditionNone = 0
$waitConditionInterruptAny = 3
$taskStateReady = 1
$taskStateWaiting = 6
$timerStateEnabled = 1
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-interrupt-timeout-disable-interrupt-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-interrupt-timeout-disable-interrupt-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-interrupt-timeout-disable-interrupt-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-interrupt-timeout-disable-interrupt-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-interrupt-timeout-disable-interrupt-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-interrupt-timeout-disable-interrupt-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-interrupt-timeout-disable-interrupt-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-interrupt-timeout-disable-interrupt-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-interrupt-timeout-disable-interrupt-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-interrupt-timeout-disable-interrupt-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for interrupt-timeout-disable-interrupt probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for interrupt-timeout-disable-interrupt probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for interrupt-timeout-disable-interrupt probe PVH artifact failed with exit code $LASTEXITCODE"
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
set `$post_wake_tick = 0
set `$paused_tick = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 0
    set `$paused_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned int*)(0x$wakeQueueCountAddress) >= 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionNone && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress) == 0 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 0
    set `$post_wake_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "AFTER_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_DISABLED\n"
    printf "DISABLED_TICK=%llu\n", `$post_wake_tick
    printf "DISABLED_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "DISABLED_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "DISABLED_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "DISABLED_TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    printf "DISABLED_WAIT_KIND0=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress)
    printf "DISABLED_WAIT_VECTOR0=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
    printf "DISABLED_WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
    printf "DISABLED_TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
    printf "DISABLED_TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    printf "DISABLED_TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    printf "DISABLED_TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    printf "DISABLED_TIMER_LAST_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastInterruptCountOffset)
    printf "DISABLED_TIMER_LAST_WAKE_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
    printf "DISABLED_WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
    printf "DISABLED_WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
    printf "DISABLED_WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    printf "DISABLED_WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
    printf "DISABLED_WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    printf "DISABLED_WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
    printf "DISABLED_WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    printf "DISABLED_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
    printf "DISABLED_LAST_INTERRUPT_VECTOR=%u\n", *(unsigned short*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerEnableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == $timerStateEnabled
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= `$post_wake_tick + $postWakeSlackTicks && *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == 0
    set `$stage = 11
  end
  continue
end
printf "AFTER_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_SETTLED\n"
printf "FINAL_TICK=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "FINAL_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "FINAL_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "FINAL_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "FINAL_TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "FINAL_WAIT_KIND0=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress)
printf "FINAL_WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
printf "FINAL_TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
printf "FINAL_TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "FINAL_TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
printf "FINAL_TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
printf "FINAL_TIMER_LAST_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastInterruptCountOffset)
printf "FINAL_TIMER_LAST_WAKE_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
printf "FINAL_WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
printf "FINAL_WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
printf "FINAL_WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "FINAL_WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "FINAL_WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "FINAL_WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "FINAL_WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
printf "FINAL_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
printf "FINAL_LAST_INTERRUPT_VECTOR=%u\n", *(unsigned short*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset)
printf "AFTER_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT\n"
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
printf "WAIT_KIND0=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress)
printf "WAIT_VECTOR0=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
printf "WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
printf "TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
printf "TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
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
printf "PAUSED_TICK=%llu\n", `$paused_tick
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
$hitAfterInterruptTimeout = $false
$hitDisabledStage = $false
$hitSettledStage = $false
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
$waitKind0 = $null
$waitVector0 = $null
$waitTimeout0 = $null
$timerEnabled = $null
$timerEntryCount = $null
$timerPendingWakeCount = $null
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
    $hitDisabledStage = $gdbOutput.Contains("AFTER_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_DISABLED")
    $hitSettledStage = $gdbOutput.Contains("AFTER_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_SETTLED")
    $hitAfterInterruptTimeout = $gdbOutput.Contains("AFTER_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT")
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
    $waitKind0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_KIND0"
    $waitVector0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_VECTOR0"
    $waitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_TIMEOUT0"
    $timerEnabled = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENABLED"
    $timerEntryCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENTRY_COUNT"
    $timerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_PENDING_WAKE_COUNT"
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
    $pausedTick = Extract-IntValue -Text $gdbOutput -Name "PAUSED_TICK"
    $disabledTick = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TICK"
    $disabledAck = Extract-IntValue -Text $gdbOutput -Name "DISABLED_ACK"
    $disabledLastOpcode = Extract-IntValue -Text $gdbOutput -Name "DISABLED_LAST_OPCODE"
    $disabledLastResult = Extract-IntValue -Text $gdbOutput -Name "DISABLED_LAST_RESULT"
    $disabledTask0State = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TASK0_STATE"
    $disabledWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAIT_KIND0"
    $disabledWaitVector0 = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAIT_VECTOR0"
    $disabledWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAIT_TIMEOUT0"
    $disabledTimerEnabled = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TIMER_ENABLED"
    $disabledTimerEntryCount = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TIMER_ENTRY_COUNT"
    $disabledTimerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TIMER_PENDING_WAKE_COUNT"
    $disabledTimerDispatchCount = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TIMER_DISPATCH_COUNT"
    $disabledTimerLastInterruptCount = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TIMER_LAST_INTERRUPT_COUNT"
    $disabledTimerLastWakeTick = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TIMER_LAST_WAKE_TICK"
    $disabledWakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAKE_QUEUE_COUNT"
    $disabledWake0Seq = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAKE0_SEQ"
    $disabledWake0TaskId = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAKE0_TASK_ID"
    $disabledWake0TimerId = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAKE0_TIMER_ID"
    $disabledWake0Reason = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAKE0_REASON"
    $disabledWake0Vector = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAKE0_VECTOR"
    $disabledWake0Tick = Extract-IntValue -Text $gdbOutput -Name "DISABLED_WAKE0_TICK"
    $disabledInterruptCount = Extract-IntValue -Text $gdbOutput -Name "DISABLED_INTERRUPT_COUNT"
    $disabledLastInterruptVector = Extract-IntValue -Text $gdbOutput -Name "DISABLED_LAST_INTERRUPT_VECTOR"
    $finalTick = Extract-IntValue -Text $gdbOutput -Name "FINAL_TICK"
    $finalAck = Extract-IntValue -Text $gdbOutput -Name "FINAL_ACK"
    $finalLastOpcode = Extract-IntValue -Text $gdbOutput -Name "FINAL_LAST_OPCODE"
    $finalLastResult = Extract-IntValue -Text $gdbOutput -Name "FINAL_LAST_RESULT"
    $finalTask0State = Extract-IntValue -Text $gdbOutput -Name "FINAL_TASK0_STATE"
    $finalWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAIT_KIND0"
    $finalWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAIT_TIMEOUT0"
    $finalTimerEnabled = Extract-IntValue -Text $gdbOutput -Name "FINAL_TIMER_ENABLED"
    $finalTimerEntryCount = Extract-IntValue -Text $gdbOutput -Name "FINAL_TIMER_ENTRY_COUNT"
    $finalTimerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "FINAL_TIMER_PENDING_WAKE_COUNT"
    $finalTimerDispatchCount = Extract-IntValue -Text $gdbOutput -Name "FINAL_TIMER_DISPATCH_COUNT"
    $finalTimerLastInterruptCount = Extract-IntValue -Text $gdbOutput -Name "FINAL_TIMER_LAST_INTERRUPT_COUNT"
    $finalTimerLastWakeTick = Extract-IntValue -Text $gdbOutput -Name "FINAL_TIMER_LAST_WAKE_TICK"
    $finalWakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAKE_QUEUE_COUNT"
    $finalWake0Seq = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAKE0_SEQ"
    $finalWake0TaskId = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAKE0_TASK_ID"
    $finalWake0TimerId = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAKE0_TIMER_ID"
    $finalWake0Reason = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAKE0_REASON"
    $finalWake0Vector = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAKE0_VECTOR"
    $finalWake0Tick = Extract-IntValue -Text $gdbOutput -Name "FINAL_WAKE0_TICK"
    $finalInterruptCount = Extract-IntValue -Text $gdbOutput -Name "FINAL_INTERRUPT_COUNT"
    $finalLastInterruptVector = Extract-IntValue -Text $gdbOutput -Name "FINAL_LAST_INTERRUPT_VECTOR"
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
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_SCHEDULER_STATE_ADDR=0x$schedulerStateAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_SCHEDULER_TASKS_ADDR=0x$schedulerTasksAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_SCHEDULER_WAIT_KIND_ADDR=0x$schedulerWaitKindAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_SCHEDULER_WAIT_INTERRUPT_VECTOR_ADDR=0x$schedulerWaitInterruptVectorAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_SCHEDULER_WAIT_TIMEOUT_TICK_ADDR=0x$schedulerWaitTimeoutTickAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_STATE_ADDR=0x$timerStateAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE_QUEUE_COUNT_ADDR=0x$wakeQueueCountAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_INTERRUPT_STATE_ADDR=0x$interruptStateAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_HIT_DISABLED_STAGE=$hitDisabledStage"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_HIT_SETTLED_STAGE=$hitSettledStage"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_HIT_AFTER_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT=$hitAfterInterruptTimeout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TASK0_STATE=$task0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TASK0_PRIORITY=$task0Priority"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TASK0_RUN_COUNT=$task0RunCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TASK0_BUDGET=$task0Budget"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAIT_KIND0=$waitKind0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAIT_VECTOR0=$waitVector0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAIT_TIMEOUT0=$waitTimeout0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_ENABLED=$timerEnabled"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_LAST_INTERRUPT_COUNT=$timerLastInterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMER_LAST_WAKE_TICK=$timerLastWakeTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TICK=$disabledTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_ACK=$disabledAck"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_LAST_OPCODE=$disabledLastOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_LAST_RESULT=$disabledLastResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TASK0_STATE=$disabledTask0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAIT_KIND0=$disabledWaitKind0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAIT_VECTOR0=$disabledWaitVector0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAIT_TIMEOUT0=$disabledWaitTimeout0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TIMER_ENABLED=$disabledTimerEnabled"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TIMER_ENTRY_COUNT=$disabledTimerEntryCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TIMER_PENDING_WAKE_COUNT=$disabledTimerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TIMER_DISPATCH_COUNT=$disabledTimerDispatchCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TIMER_LAST_INTERRUPT_COUNT=$disabledTimerLastInterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_TIMER_LAST_WAKE_TICK=$disabledTimerLastWakeTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAKE_QUEUE_COUNT=$disabledWakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAKE0_SEQ=$disabledWake0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAKE0_TASK_ID=$disabledWake0TaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAKE0_TIMER_ID=$disabledWake0TimerId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAKE0_REASON=$disabledWake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAKE0_VECTOR=$disabledWake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_WAKE0_TICK=$disabledWake0Tick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_INTERRUPT_COUNT=$disabledInterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_DISABLED_LAST_INTERRUPT_VECTOR=$disabledLastInterruptVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_PAUSED_TICK=$pausedTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TICK=$finalTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_ACK=$finalAck"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_LAST_OPCODE=$finalLastOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_LAST_RESULT=$finalLastResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TASK0_STATE=$finalTask0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAIT_KIND0=$finalWaitKind0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAIT_TIMEOUT0=$finalWaitTimeout0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TIMER_ENABLED=$finalTimerEnabled"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TIMER_ENTRY_COUNT=$finalTimerEntryCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TIMER_PENDING_WAKE_COUNT=$finalTimerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TIMER_DISPATCH_COUNT=$finalTimerDispatchCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TIMER_LAST_INTERRUPT_COUNT=$finalTimerLastInterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_TIMER_LAST_WAKE_TICK=$finalTimerLastWakeTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAKE_QUEUE_COUNT=$finalWakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAKE0_SEQ=$finalWake0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAKE0_TASK_ID=$finalWake0TaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAKE0_TIMER_ID=$finalWake0TimerId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAKE0_REASON=$finalWake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAKE0_VECTOR=$finalWake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_WAKE0_TICK=$finalWake0Tick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_INTERRUPT_COUNT=$finalInterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_FINAL_LAST_INTERRUPT_VECTOR=$finalLastInterruptVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_INTERRUPT_COUNT=$interruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE_TIMED_OUT=$timedOut"

$probePassed = $hitStart -and
    $hitDisabledStage -and
    $hitSettledStage -and
    $hitAfterInterruptTimeout -and
    (-not $timedOut) -and
    ($ack -eq ($triggerInterruptOpcode + 1)) -and
    ($lastOpcode -eq $triggerInterruptOpcode) -and
    ($lastResult -eq 0) -and
    ($mailboxOpcode -eq $timerEnableOpcode) -and
    ($mailboxSeq -eq 9) -and
    ($schedTaskCount -eq 1) -and
    ($task0Id -eq 1) -and
    ($task0State -eq $taskStateReady) -and
    ($task0Priority -eq $taskPriority) -and
    ($task0RunCount -eq 0) -and
    ($task0Budget -eq $taskBudget) -and
    ($task0BudgetRemaining -eq $taskBudget) -and
    ($waitKind0 -eq $waitConditionNone) -and
    ($waitVector0 -eq 0) -and
    ($waitTimeout0 -eq 0) -and
    ($timerEnabled -eq 0) -and
    ($timerEntryCount -eq 0) -and
    ($timerPendingWakeCount -eq 1) -and
    ($timerDispatchCount -eq 0) -and
    ($timerLastInterruptCount -eq 1) -and
    ($wakeQueueCount -eq 1) -and
    ($wake0Seq -eq 1) -and
    ($wake0TaskId -eq 1) -and
    ($wake0TimerId -eq 0) -and
    ($wake0Reason -eq $wakeReasonInterrupt) -and
    ($wake0Vector -eq $interruptVector) -and
    ($pausedTick -gt 0) -and
    ($wake0Tick -ge $pausedTick) -and
    ($disabledTick -ge $wake0Tick) -and
    ($disabledAck -eq $triggerInterruptOpcode + 1) -and
    ($disabledLastOpcode -eq $triggerInterruptOpcode) -and
    ($disabledLastResult -eq 0) -and
    ($disabledTask0State -eq $taskStateReady) -and
    ($disabledWaitKind0 -eq $waitConditionNone) -and
    ($disabledWaitVector0 -eq 0) -and
    ($disabledWaitTimeout0 -eq 0) -and
    ($disabledTimerEnabled -eq 0) -and
    ($disabledTimerEntryCount -eq 0) -and
    ($disabledTimerPendingWakeCount -eq 1) -and
    ($disabledTimerDispatchCount -eq 0) -and
    ($disabledTimerLastInterruptCount -eq 1) -and
    ($disabledTimerLastWakeTick -eq $disabledWake0Tick) -and
    ($disabledWakeQueueCount -eq 1) -and
    ($disabledWake0Seq -eq 1) -and
    ($disabledWake0TaskId -eq 1) -and
    ($disabledWake0TimerId -eq 0) -and
    ($disabledWake0Reason -eq $wakeReasonInterrupt) -and
    ($disabledWake0Vector -eq $interruptVector) -and
    ($disabledInterruptCount -eq 1) -and
    ($disabledLastInterruptVector -eq $interruptVector) -and
    ($finalTick -eq $ticks) -and
    ($finalTask0State -eq $taskStateReady) -and
    ($finalWaitKind0 -eq $waitConditionNone) -and
    ($finalWaitTimeout0 -eq 0) -and
    ($finalTimerEnabled -eq $timerStateEnabled) -and
    ($finalTimerEntryCount -eq 0) -and
    ($finalTimerPendingWakeCount -eq 1) -and
    ($finalTimerDispatchCount -eq 0) -and
    ($finalTimerLastInterruptCount -eq 1) -and
    ($finalTimerLastWakeTick -eq $finalWake0Tick) -and
    ($finalWakeQueueCount -eq 1) -and
    ($finalWake0Seq -eq 1) -and
    ($finalWake0TaskId -eq 1) -and
    ($finalWake0TimerId -eq 0) -and
    ($finalWake0Reason -eq $wakeReasonInterrupt) -and
    ($finalWake0Vector -eq $interruptVector) -and
    ($finalInterruptCount -eq 1) -and
    ($finalLastInterruptVector -eq $interruptVector) -and
    ($interruptCount -eq 1) -and
    ($lastInterruptVector -eq $interruptVector) -and
    ($timerLastWakeTick -eq $wake0Tick) -and
    ($finalAck -eq $mailboxSeq) -and
    ($finalLastOpcode -eq $timerEnableOpcode) -and
    ($finalLastResult -eq 0) -and
    ($ticks -ge ($wake0Tick + $postWakeSlackTicks))

Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_DISABLE_INTERRUPT_PROBE=$($(if ($probePassed) { 'pass' } else { 'fail' }))"

if (-not $probePassed) {
    if (Test-Path $gdbStderr) {
        Get-Content -Path $gdbStderr | Write-Error
    }
    exit 1
}



