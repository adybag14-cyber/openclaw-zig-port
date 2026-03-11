param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$schedulerResetOpcode = 26
$timerResetOpcode = 41
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$taskCreateOpcode = 27
$schedulerDisableOpcode = 25
$taskWaitInterruptOpcode = 57
$triggerInterruptOpcode = 7

$taskBudget = 5
$taskPriority = 0
$anyInterruptVector = 200
$specificInterruptVector = 13
$nonMatchingInterruptVector = 200
$invalidInterruptVector = 65536

$waitConditionNone = 0
$waitConditionInterruptAny = 3
$waitConditionInterruptVector = 4
$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonInterrupt = 2
$resultInvalidArgument = -22

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
$waitSlotStride = 1

$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetOffset = 12
$taskBudgetRemainingOffset = 16

$interruptStateLastInterruptVectorOffset = 2
$interruptStateInterruptCountOffset = 16

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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-interrupt-filter-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-interrupt-filter-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-interrupt-filter-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-interrupt-filter-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-interrupt-filter-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-interrupt-filter-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-interrupt-filter-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-interrupt-filter-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-interrupt-filter-probe-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-interrupt-filter-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for interrupt-filter probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for interrupt-filter probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for interrupt-filter probe PVH artifact failed with exit code $LASTEXITCODE"
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
set `$task_any_id = 0
set `$task_vec_id = 0
set `$any_wait_count_before_wake = 0
set `$any_wait_kind_before_wake = 0
set `$any_wait_vector_before_wake = 0
set `$any_wait_task_count_before_wake = 0
set `$any_wait_task_state_before_wake = 0
set `$any_wake_seq = 0
set `$any_wake_tick = 0
set `$any_wake_task_state = 0
set `$any_wake_task_count = 0
set `$any_wake_task_id = 0
set `$any_wake_reason = 0
set `$any_wake_vector = 0
set `$vec_wait_count_before_match = 0
set `$vec_wait_kind_before_match = 0
set `$vec_wait_vector_before_match = 0
set `$vec_wait_task_count_before_match = 0
set `$vec_wait_task_state_before_match = 0
set `$vec_wait_wake_queue_len_before_match = 0
set `$vec_wake_seq = 0
set `$vec_wake_tick = 0
set `$vec_wake_task_state = 0
set `$vec_wake_task_count = 0
set `$vec_wake_task_id = 0
set `$vec_wake_reason = 0
set `$vec_wake_vector = 0
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
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$task_any_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_any_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 65535
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionInterruptAny && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set `$any_wait_count_before_wake = 1
    set `$any_wait_kind_before_wake = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set `$any_wait_vector_before_wake = *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
    set `$any_wait_task_count_before_wake = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$any_wait_task_state_before_wake = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $anyInterruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionNone
    set `$any_wake_seq = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
    set `$any_wake_tick = *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    set `$any_wake_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$any_wake_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$any_wake_task_id = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    set `$any_wake_reason = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    set `$any_wake_vector = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset) != 0
    set `$task_vec_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_vec_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $specificInterruptVector
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress+$waitSlotStride) == $waitConditionInterruptVector && *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress+$waitSlotStride) == $specificInterruptVector && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $nonMatchingInterruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12 && *(unsigned int*)(0x$wakeQueueCountAddress) == 0 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress+$waitSlotStride) == $waitConditionInterruptVector
    set `$vec_wait_kind_before_match = *(unsigned char*)(0x$schedulerWaitKindAddress+$waitSlotStride)
    set `$vec_wait_vector_before_match = *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress+$waitSlotStride)
    set `$vec_wait_count_before_match = 1
    set `$vec_wait_task_count_before_match = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$vec_wait_task_state_before_match = *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
    set `$vec_wait_wake_queue_len_before_match = *(unsigned int*)(0x$wakeQueueCountAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $specificInterruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 13
  end
  continue
end
if `$stage == 13
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 13 && *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerWaitKindAddress+$waitSlotStride) == $waitConditionNone
    set `$vec_wake_seq = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
    set `$vec_wake_tick = *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    set `$vec_wake_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
    set `$vec_wake_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$vec_wake_task_id = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    set `$vec_wake_reason = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    set `$vec_wake_vector = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 14
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_vec_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $invalidInterruptVector
    set `$stage = 14
  end
  continue
end
if `$stage == 14
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 14 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultInvalidArgument
    set `$stage = 15
  end
  continue
end
printf "AFTER_INTERRUPT_FILTER\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "TASK0_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
printf "TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "TASK0_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "TASK0_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
printf "TASK0_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetOffset)
printf "TASK0_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
printf "TASK1_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset)
printf "TASK1_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
printf "TASK1_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskPriorityOffset)
printf "TASK1_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset)
printf "TASK1_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetOffset)
printf "TASK1_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetRemainingOffset)
printf "WAIT_KIND0=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress)
printf "WAIT_VECTOR0=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
printf "WAIT_KIND1=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress+$waitSlotStride)
printf "WAIT_VECTOR1=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress+$waitSlotStride)
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
printf "WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
printf "ANY_WAIT_COUNT_BEFORE_WAKE=%u\n", `$any_wait_count_before_wake
printf "ANY_WAIT_KIND_BEFORE_WAKE=%u\n", `$any_wait_kind_before_wake
printf "ANY_WAIT_VECTOR_BEFORE_WAKE=%u\n", `$any_wait_vector_before_wake
printf "ANY_WAIT_TASK_COUNT_BEFORE_WAKE=%u\n", `$any_wait_task_count_before_wake
printf "ANY_WAIT_TASK_STATE_BEFORE_WAKE=%u\n", `$any_wait_task_state_before_wake
printf "ANY_WAKE_SEQ=%u\n", `$any_wake_seq
printf "ANY_WAKE_TICK=%llu\n", `$any_wake_tick
printf "ANY_WAKE_TASK_STATE=%u\n", `$any_wake_task_state
printf "ANY_WAKE_TASK_COUNT=%u\n", `$any_wake_task_count
printf "ANY_WAKE_TASK_ID=%u\n", `$any_wake_task_id
printf "ANY_WAKE_REASON=%u\n", `$any_wake_reason
printf "ANY_WAKE_VECTOR=%u\n", `$any_wake_vector
printf "VEC_WAIT_COUNT_BEFORE_MATCH=%u\n", `$vec_wait_count_before_match
printf "VEC_WAIT_KIND_BEFORE_MATCH=%u\n", `$vec_wait_kind_before_match
printf "VEC_WAIT_VECTOR_BEFORE_MATCH=%u\n", `$vec_wait_vector_before_match
printf "VEC_WAIT_TASK_COUNT_BEFORE_MATCH=%u\n", `$vec_wait_task_count_before_match
printf "VEC_WAIT_TASK_STATE_BEFORE_MATCH=%u\n", `$vec_wait_task_state_before_match
printf "VEC_WAIT_WAKE_QUEUE_LEN_BEFORE_MATCH=%u\n", `$vec_wait_wake_queue_len_before_match
printf "VEC_WAKE_SEQ=%u\n", `$vec_wake_seq
printf "VEC_WAKE_TICK=%llu\n", `$vec_wake_tick
printf "VEC_WAKE_TASK_STATE=%u\n", `$vec_wake_task_state
printf "VEC_WAKE_TASK_COUNT=%u\n", `$vec_wake_task_count
printf "VEC_WAKE_TASK_ID=%u\n", `$vec_wake_task_id
printf "VEC_WAKE_REASON=%u\n", `$vec_wake_reason
printf "VEC_WAKE_VECTOR=%u\n", `$vec_wake_vector
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

$gdbOutput = ""
$gdbError = ""
$hitStart = $false
$hitAfter = $false
if (Test-Path $gdbStdout) {
    $gdbOutput = [string](Get-Content -Path $gdbStdout -Raw)
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfter = $gdbOutput.Contains("AFTER_INTERRUPT_FILTER")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU interrupt-filter probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfter) {
    throw "Interrupt-filter probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskCount = Extract-IntValue -Text $gdbOutput -Name "TASK_COUNT"
$task0Id = Extract-IntValue -Text $gdbOutput -Name "TASK0_ID"
$task0State = Extract-IntValue -Text $gdbOutput -Name "TASK0_STATE"
$task0Priority = Extract-IntValue -Text $gdbOutput -Name "TASK0_PRIORITY"
$task0RunCount = Extract-IntValue -Text $gdbOutput -Name "TASK0_RUN_COUNT"
$task0Budget = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET"
$task0BudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET_REMAINING"
$task1Id = Extract-IntValue -Text $gdbOutput -Name "TASK1_ID"
$task1State = Extract-IntValue -Text $gdbOutput -Name "TASK1_STATE"
$task1Priority = Extract-IntValue -Text $gdbOutput -Name "TASK1_PRIORITY"
$task1RunCount = Extract-IntValue -Text $gdbOutput -Name "TASK1_RUN_COUNT"
$task1Budget = Extract-IntValue -Text $gdbOutput -Name "TASK1_BUDGET"
$task1BudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "TASK1_BUDGET_REMAINING"
$waitKind0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_KIND0"
$waitVector0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_VECTOR0"
$waitKind1 = Extract-IntValue -Text $gdbOutput -Name "WAIT_KIND1"
$waitVector1 = Extract-IntValue -Text $gdbOutput -Name "WAIT_VECTOR1"
$wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
$wake0Seq = Extract-IntValue -Text $gdbOutput -Name "WAKE0_SEQ"
$wake0TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TASK_ID"
$wake0TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TIMER_ID"
$wake0Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE0_REASON"
$wake0Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE0_VECTOR"
$wake0Tick = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TICK"
$anyWaitCountBeforeWake = Extract-IntValue -Text $gdbOutput -Name "ANY_WAIT_COUNT_BEFORE_WAKE"
$anyWaitKindBeforeWake = Extract-IntValue -Text $gdbOutput -Name "ANY_WAIT_KIND_BEFORE_WAKE"
$anyWaitVectorBeforeWake = Extract-IntValue -Text $gdbOutput -Name "ANY_WAIT_VECTOR_BEFORE_WAKE"
$anyWaitTaskCountBeforeWake = Extract-IntValue -Text $gdbOutput -Name "ANY_WAIT_TASK_COUNT_BEFORE_WAKE"
$anyWaitTaskStateBeforeWake = Extract-IntValue -Text $gdbOutput -Name "ANY_WAIT_TASK_STATE_BEFORE_WAKE"
$anyWakeSeq = Extract-IntValue -Text $gdbOutput -Name "ANY_WAKE_SEQ"
$anyWakeTick = Extract-IntValue -Text $gdbOutput -Name "ANY_WAKE_TICK"
$anyWakeTaskState = Extract-IntValue -Text $gdbOutput -Name "ANY_WAKE_TASK_STATE"
$anyWakeTaskCount = Extract-IntValue -Text $gdbOutput -Name "ANY_WAKE_TASK_COUNT"
$anyWakeTaskId = Extract-IntValue -Text $gdbOutput -Name "ANY_WAKE_TASK_ID"
$anyWakeReason = Extract-IntValue -Text $gdbOutput -Name "ANY_WAKE_REASON"
$anyWakeVector = Extract-IntValue -Text $gdbOutput -Name "ANY_WAKE_VECTOR"
$vecWaitCountBeforeMatch = Extract-IntValue -Text $gdbOutput -Name "VEC_WAIT_COUNT_BEFORE_MATCH"
$vecWaitKindBeforeMatch = Extract-IntValue -Text $gdbOutput -Name "VEC_WAIT_KIND_BEFORE_MATCH"
$vecWaitVectorBeforeMatch = Extract-IntValue -Text $gdbOutput -Name "VEC_WAIT_VECTOR_BEFORE_MATCH"
$vecWaitTaskCountBeforeMatch = Extract-IntValue -Text $gdbOutput -Name "VEC_WAIT_TASK_COUNT_BEFORE_MATCH"
$vecWaitTaskStateBeforeMatch = Extract-IntValue -Text $gdbOutput -Name "VEC_WAIT_TASK_STATE_BEFORE_MATCH"
$vecWaitWakeQueueLenBeforeMatch = Extract-IntValue -Text $gdbOutput -Name "VEC_WAIT_WAKE_QUEUE_LEN_BEFORE_MATCH"
$vecWakeSeq = Extract-IntValue -Text $gdbOutput -Name "VEC_WAKE_SEQ"
$vecWakeTick = Extract-IntValue -Text $gdbOutput -Name "VEC_WAKE_TICK"
$vecWakeTaskState = Extract-IntValue -Text $gdbOutput -Name "VEC_WAKE_TASK_STATE"
$vecWakeTaskCount = Extract-IntValue -Text $gdbOutput -Name "VEC_WAKE_TASK_COUNT"
$vecWakeTaskId = Extract-IntValue -Text $gdbOutput -Name "VEC_WAKE_TASK_ID"
$vecWakeReason = Extract-IntValue -Text $gdbOutput -Name "VEC_WAKE_REASON"
$vecWakeVector = Extract-IntValue -Text $gdbOutput -Name "VEC_WAKE_VECTOR"
$interruptCount = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_COUNT"
$lastInterruptVector = Extract-IntValue -Text $gdbOutput -Name "LAST_INTERRUPT_VECTOR"

if ($ack -ne 14) { throw "Expected ACK=14, got $ack" }
if ($lastOpcode -ne $taskWaitInterruptOpcode) { throw "Expected LAST_OPCODE=$taskWaitInterruptOpcode, got $lastOpcode" }
if ($lastResult -ne $resultInvalidArgument) { throw "Expected LAST_RESULT=$resultInvalidArgument, got $lastResult" }
if ($ticks -lt 12) { throw "Expected TICKS >= 12, got $ticks" }
if ($taskCount -ne 2) { throw "Expected TASK_COUNT=2, got $taskCount" }
if ($task0Id -le 0) { throw "Expected TASK0_ID > 0, got $task0Id" }
if ($task1Id -le $task0Id) { throw "Expected TASK1_ID > TASK0_ID, got TASK0_ID=$task0Id TASK1_ID=$task1Id" }
if ($task0State -ne $taskStateReady) { throw "Expected TASK0_STATE=$taskStateReady, got $task0State" }
if ($task1State -ne $taskStateReady) { throw "Expected TASK1_STATE=$taskStateReady, got $task1State" }
if ($task0Priority -ne $taskPriority) { throw "Expected TASK0_PRIORITY=$taskPriority, got $task0Priority" }
if ($task1Priority -ne $taskPriority) { throw "Expected TASK1_PRIORITY=$taskPriority, got $task1Priority" }
if ($task0RunCount -ne 0) { throw "Expected TASK0_RUN_COUNT=0, got $task0RunCount" }
if ($task1RunCount -ne 0) { throw "Expected TASK1_RUN_COUNT=0, got $task1RunCount" }
if ($task0Budget -ne $taskBudget) { throw "Expected TASK0_BUDGET=$taskBudget, got $task0Budget" }
if ($task1Budget -ne $taskBudget) { throw "Expected TASK1_BUDGET=$taskBudget, got $task1Budget" }
if ($task0BudgetRemaining -ne $taskBudget) { throw "Expected TASK0_BUDGET_REMAINING=$taskBudget, got $task0BudgetRemaining" }
if ($task1BudgetRemaining -ne $taskBudget) { throw "Expected TASK1_BUDGET_REMAINING=$taskBudget, got $task1BudgetRemaining" }
if ($waitKind0 -ne $waitConditionNone) { throw "Expected WAIT_KIND0=$waitConditionNone, got $waitKind0" }
if ($waitVector0 -ne 0) { throw "Expected WAIT_VECTOR0=0, got $waitVector0" }
if ($waitKind1 -ne $waitConditionNone) { throw "Expected WAIT_KIND1=$waitConditionNone, got $waitKind1" }
if ($waitVector1 -ne 0) { throw "Expected WAIT_VECTOR1=0 after wake, got $waitVector1" }
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1, got $wakeQueueCount" }
if ($wake0TaskId -ne $task1Id) { throw "Expected WAKE0_TASK_ID=$task1Id, got $wake0TaskId" }
if ($wake0TimerId -ne 0) { throw "Expected WAKE0_TIMER_ID=0, got $wake0TimerId" }
if ($wake0Reason -ne $wakeReasonInterrupt) { throw "Expected WAKE0_REASON=$wakeReasonInterrupt, got $wake0Reason" }
if ($wake0Vector -ne $specificInterruptVector) { throw "Expected WAKE0_VECTOR=$specificInterruptVector, got $wake0Vector" }
if ($anyWaitCountBeforeWake -ne 1) { throw "Expected ANY_WAIT_COUNT_BEFORE_WAKE=1, got $anyWaitCountBeforeWake" }
if ($anyWaitKindBeforeWake -ne $waitConditionInterruptAny) { throw "Expected ANY_WAIT_KIND_BEFORE_WAKE=$waitConditionInterruptAny, got $anyWaitKindBeforeWake" }
if ($anyWaitVectorBeforeWake -ne 0) { throw "Expected ANY_WAIT_VECTOR_BEFORE_WAKE=0, got $anyWaitVectorBeforeWake" }
if ($anyWaitTaskCountBeforeWake -ne 0) { throw "Expected ANY_WAIT_TASK_COUNT_BEFORE_WAKE=0, got $anyWaitTaskCountBeforeWake" }
if ($anyWaitTaskStateBeforeWake -ne $taskStateWaiting) { throw "Expected ANY_WAIT_TASK_STATE_BEFORE_WAKE=$taskStateWaiting, got $anyWaitTaskStateBeforeWake" }
if ($anyWakeSeq -le 0) { throw "Expected ANY_WAKE_SEQ > 0, got $anyWakeSeq" }
if ($anyWakeTaskState -ne $taskStateReady) { throw "Expected ANY_WAKE_TASK_STATE=$taskStateReady, got $anyWakeTaskState" }
if ($anyWakeTaskCount -ne 1) { throw "Expected ANY_WAKE_TASK_COUNT=1, got $anyWakeTaskCount" }
if ($anyWakeTaskId -ne $task0Id) { throw "Expected ANY_WAKE_TASK_ID=$task0Id, got $anyWakeTaskId" }
if ($anyWakeReason -ne $wakeReasonInterrupt) { throw "Expected ANY_WAKE_REASON=$wakeReasonInterrupt, got $anyWakeReason" }
if ($anyWakeVector -ne $anyInterruptVector) { throw "Expected ANY_WAKE_VECTOR=$anyInterruptVector, got $anyWakeVector" }
if ($vecWaitCountBeforeMatch -ne 1) { throw "Expected VEC_WAIT_COUNT_BEFORE_MATCH=1, got $vecWaitCountBeforeMatch" }
if ($vecWaitKindBeforeMatch -ne $waitConditionInterruptVector) { throw "Expected VEC_WAIT_KIND_BEFORE_MATCH=$waitConditionInterruptVector, got $vecWaitKindBeforeMatch" }
if ($vecWaitVectorBeforeMatch -ne $specificInterruptVector) { throw "Expected VEC_WAIT_VECTOR_BEFORE_MATCH=$specificInterruptVector, got $vecWaitVectorBeforeMatch" }
if ($vecWaitTaskCountBeforeMatch -ne 1) { throw "Expected VEC_WAIT_TASK_COUNT_BEFORE_MATCH=1, got $vecWaitTaskCountBeforeMatch" }
if ($vecWaitTaskStateBeforeMatch -ne $taskStateWaiting) { throw "Expected VEC_WAIT_TASK_STATE_BEFORE_MATCH=$taskStateWaiting, got $vecWaitTaskStateBeforeMatch" }
if ($vecWaitWakeQueueLenBeforeMatch -ne 0) { throw "Expected VEC_WAIT_WAKE_QUEUE_LEN_BEFORE_MATCH=0, got $vecWaitWakeQueueLenBeforeMatch" }
if ($vecWakeSeq -le 0) { throw "Expected VEC_WAKE_SEQ > 0, got $vecWakeSeq" }
if ($vecWakeTick -le $anyWakeTick) { throw "Expected VEC_WAKE_TICK > ANY_WAKE_TICK, got ANY_WAKE_TICK=$anyWakeTick VEC_WAKE_TICK=$vecWakeTick" }
if ($vecWakeTaskState -ne $taskStateReady) { throw "Expected VEC_WAKE_TASK_STATE=$taskStateReady, got $vecWakeTaskState" }
if ($vecWakeTaskCount -ne 2) { throw "Expected VEC_WAKE_TASK_COUNT=2, got $vecWakeTaskCount" }
if ($vecWakeTaskId -ne $task1Id) { throw "Expected VEC_WAKE_TASK_ID=$task1Id, got $vecWakeTaskId" }
if ($vecWakeReason -ne $wakeReasonInterrupt) { throw "Expected VEC_WAKE_REASON=$wakeReasonInterrupt, got $vecWakeReason" }
if ($vecWakeVector -ne $specificInterruptVector) { throw "Expected VEC_WAKE_VECTOR=$specificInterruptVector, got $vecWakeVector" }
if ($wake0Seq -ne $vecWakeSeq) { throw "Expected WAKE0_SEQ=$vecWakeSeq, got $wake0Seq" }
if ($wake0Tick -ne $vecWakeTick) { throw "Expected WAKE0_TICK=$vecWakeTick, got $wake0Tick" }
if ($interruptCount -lt 3) { throw "Expected INTERRUPT_COUNT >= 3, got $interruptCount" }
if ($lastInterruptVector -ne $specificInterruptVector) { throw "Expected LAST_INTERRUPT_VECTOR=$specificInterruptVector, got $lastInterruptVector" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_PROBE=pass"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ACK=$ack"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_TASK_COUNT=$taskCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_TASK1_ID=$task1Id"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAIT_COUNT_BEFORE_WAKE=$anyWaitCountBeforeWake"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAIT_KIND_BEFORE_WAKE=$anyWaitKindBeforeWake"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAIT_VECTOR_BEFORE_WAKE=$anyWaitVectorBeforeWake"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAIT_TASK_COUNT_BEFORE_WAKE=$anyWaitTaskCountBeforeWake"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAIT_TASK_STATE_BEFORE_WAKE=$anyWaitTaskStateBeforeWake"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAKE_SEQ=$anyWakeSeq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAKE_TICK=$anyWakeTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAKE_TASK_STATE=$anyWakeTaskState"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAKE_TASK_COUNT=$anyWakeTaskCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAKE_TASK_ID=$anyWakeTaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAKE_REASON=$anyWakeReason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_ANY_WAKE_VECTOR=$anyWakeVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_COUNT_BEFORE_MATCH=$vecWaitCountBeforeMatch"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_KIND_BEFORE_MATCH=$vecWaitKindBeforeMatch"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_VECTOR_BEFORE_MATCH=$vecWaitVectorBeforeMatch"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_TASK_COUNT_BEFORE_MATCH=$vecWaitTaskCountBeforeMatch"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_TASK_STATE_BEFORE_MATCH=$vecWaitTaskStateBeforeMatch"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAIT_WAKE_QUEUE_LEN_BEFORE_MATCH=$vecWaitWakeQueueLenBeforeMatch"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAKE_SEQ=$vecWakeSeq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAKE_TICK=$vecWakeTick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAKE_TASK_STATE=$vecWakeTaskState"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAKE_TASK_COUNT=$vecWakeTaskCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAKE_TASK_ID=$vecWakeTaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAKE_REASON=$vecWakeReason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_VEC_WAKE_VECTOR=$vecWakeVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_FINAL_TASK1_STATE=$task1State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_FINAL_WAIT_KIND1=$waitKind1"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_FINAL_WAIT_VECTOR1=$waitVector1"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_FINAL_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_FINAL_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_FINAL_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_FINAL_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_INTERRUPT_COUNT=$interruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_FILTER_LAST_INTERRUPT_VECTOR=$lastInterruptVector"
