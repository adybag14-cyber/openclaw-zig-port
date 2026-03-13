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
$schedulerDisableOpcode = 25
$taskWaitForOpcode = 53
$taskWaitInterruptOpcode = 57
$triggerInterruptOpcode = 7
$taskWaitOpcode = 50
$schedulerWakeTaskOpcode = 45
$wakeQueuePopReasonOpcode = 59
$wakeQueuePopVectorOpcode = 60
$wakeQueuePopBeforeTickOpcode = 61
$wakeQueuePopReasonVectorOpcode = 62

$taskBudget = 5
$taskPriority = 0
$timerDelay = 2
$interruptVectorA = 13
$interruptVectorB = 31
$postDrainSlackTicks = 4

$taskIdTimer = 1
$taskIdInterruptA1 = 2
$taskIdInterruptA2 = 3
$taskIdInterruptB = 4
$taskIdManual = 5

$wakeReasonTimer = 1
$wakeReasonInterrupt = 2
$wakeReasonManual = 3
$resultOk = 0

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$wakeEventStride = 32
$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventTimerIdOffset = 8
$wakeEventReasonOffset = 12
$wakeEventVectorOffset = 13
$wakeEventTickOffset = 16

$countQueryVectorOffset = 0
$countQueryReasonOffset = 1
$countQueryMaxTickOffset = 8

$countSnapshotVectorCountOffset = 0
$countSnapshotBeforeTickCountOffset = 4
$countSnapshotReasonVectorCountOffset = 8

$timerPendingWakeCountOffset = 2

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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-wake-queue-count-snapshot-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-wake-queue-count-snapshot-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-wake-queue-count-snapshot-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-wake-queue-count-snapshot-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-wake-queue-count-snapshot-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-wake-queue-count-snapshot-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-wake-queue-count-snapshot-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-wake-queue-count-snapshot-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-wake-queue-count-snapshot-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-wake-queue-count-snapshot-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for wake-queue-count-snapshot probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for wake-queue-count-snapshot probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for wake-queue-count-snapshot probe PVH artifact failed with exit code $LASTEXITCODE"
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
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName "baremetal_main.timer_state"
$wakeQueueCountQueryPtrAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\soc_wake_queue_count_query_ptr$' -SymbolName "oc_wake_queue_count_query_ptr"
$wakeQueueCountSnapshotPtrAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\soc_wake_queue_count_snapshot_ptr$' -SymbolName "oc_wake_queue_count_snapshot_ptr"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }
@"
set pagination off
set confirm off
set `$stage = 0
set `$final_tick = 0
set `$pre_len = 0
set `$post_reason_len = 0
set `$post_vector_len = 0
set `$post_reason_vector_len = 0
set `$post_before_tick_len = 0
set `$pre_oldest_tick = 0
set `$pre_newest_tick = 0
set `$before_tick_cutoff = 0
set `$pre_task0 = 0
set `$pre_task1 = 0
set `$pre_task2 = 0
set `$pre_task3 = 0
set `$pre_task4 = 0
set `$post_reason_task1 = 0
set `$post_vector_task1 = 0
set `$post_reason_vector_task0 = 0
set `$post_reason_vector_task1 = 0
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
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskIdTimer
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timerDelay
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset) == $wakeReasonTimer && *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset) == $taskIdTimer
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskIdInterruptA1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptVectorA
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVectorA
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$wakeQueueCountAddress) == 2 && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventVectorOffset) == $interruptVectorA && *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTaskIdOffset) == $taskIdInterruptA1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskIdInterruptA2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptVectorA
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVectorA
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 13
  end
  continue
end
if `$stage == 13
  if *(unsigned int*)(0x$wakeQueueCountAddress) == 3 && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventVectorOffset) == $interruptVectorA && *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventTaskIdOffset) == $taskIdInterruptA2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 14
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 14
  end
  continue
end
if `$stage == 14
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 14
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 15
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskIdInterruptB
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptVectorB
    set `$stage = 15
  end
  continue
end
if `$stage == 15
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 15
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 16
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVectorB
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 16
  end
  continue
end
if `$stage == 16
  if *(unsigned int*)(0x$wakeQueueCountAddress) == 4 && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*3)+$wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*3)+$wakeEventVectorOffset) == $interruptVectorB && *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*3)+$wakeEventTaskIdOffset) == $taskIdInterruptB
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 17
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 17
  end
  continue
end
if `$stage == 17
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 17
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 18
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskIdManual
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 18
  end
  continue
end
if `$stage == 18
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 18
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 19
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskIdManual
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 19
  end
  continue
end
if `$stage == 19
  if *(unsigned int*)(0x$wakeQueueCountAddress) == 5 && *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset) == $taskIdTimer && *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTaskIdOffset) == $taskIdInterruptA1 && *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventTaskIdOffset) == $taskIdInterruptA2 && *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*3)+$wakeEventTaskIdOffset) == $taskIdInterruptB && *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*4)+$wakeEventTaskIdOffset) == $taskIdManual && *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset) == $wakeReasonTimer && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*4)+$wakeEventReasonOffset) == $wakeReasonManual
    set `$pre_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$pre_task0 = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    set `$pre_task1 = *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTaskIdOffset)
    set `$pre_task2 = *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*2)+$wakeEventTaskIdOffset)
    set `$pre_task3 = *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*3)+$wakeEventTaskIdOffset)
    set `$pre_task4 = *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*4)+$wakeEventTaskIdOffset)
    set `$pre_oldest_tick = *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    set `$pre_newest_tick = *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*4)+$wakeEventTickOffset)
    set `$query1_tick = *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTickOffset)
    set `$query2_tick = *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*3)+$wakeEventTickOffset)
    set `$query3_tick = *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*4)+$wakeEventTickOffset)
    set `$count_query_ptr = ((unsigned long long (*)())0x$wakeQueueCountQueryPtrAddress)()
    set *(unsigned char*)(`$count_query_ptr+$countQueryVectorOffset) = $interruptVectorA
    set *(unsigned char*)(`$count_query_ptr+$countQueryReasonOffset) = $wakeReasonInterrupt
    set *(unsigned long long*)(`$count_query_ptr+$countQueryMaxTickOffset) = `$query1_tick
    set `$count_snapshot_ptr = ((unsigned long long (*)())0x$wakeQueueCountSnapshotPtrAddress)()
    set `$query1_vector_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotVectorCountOffset)
    set `$query1_before_tick_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotBeforeTickCountOffset)
    set `$query1_reason_vector_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotReasonVectorCountOffset)
    set *(unsigned char*)(`$count_query_ptr+$countQueryVectorOffset) = $interruptVectorB
    set *(unsigned char*)(`$count_query_ptr+$countQueryReasonOffset) = $wakeReasonInterrupt
    set *(unsigned long long*)(`$count_query_ptr+$countQueryMaxTickOffset) = `$query2_tick
    set `$count_snapshot_ptr = ((unsigned long long (*)())0x$wakeQueueCountSnapshotPtrAddress)()
    set `$query2_vector_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotVectorCountOffset)
    set `$query2_before_tick_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotBeforeTickCountOffset)
    set `$query2_reason_vector_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotReasonVectorCountOffset)
    set *(unsigned char*)(`$count_query_ptr+$countQueryVectorOffset) = $interruptVectorB
    set *(unsigned char*)(`$count_query_ptr+$countQueryReasonOffset) = $wakeReasonManual
    set *(unsigned long long*)(`$count_query_ptr+$countQueryMaxTickOffset) = `$query3_tick
    set `$count_snapshot_ptr = ((unsigned long long (*)())0x$wakeQueueCountSnapshotPtrAddress)()
    set `$query3_vector_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotVectorCountOffset)
    set `$query3_before_tick_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotBeforeTickCountOffset)
    set `$query3_reason_vector_count = *(unsigned int*)(`$count_snapshot_ptr+$countSnapshotReasonVectorCountOffset)
    set `$stage = 20
  end
  continue
end
if `$stage == 20
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 19 && *(unsigned int*)(0x$wakeQueueCountAddress) == 5
    set `$stage = 21
  end
  continue
end
printf "AFTER_WAKE_QUEUE_COUNT_SNAPSHOT\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
printf "PRE_LEN=%u\n", `$pre_len
printf "PRE_TASK0=%u\n", `$pre_task0
printf "PRE_TASK1=%u\n", `$pre_task1
printf "PRE_TASK2=%u\n", `$pre_task2
printf "PRE_TASK3=%u\n", `$pre_task3
printf "PRE_TASK4=%u\n", `$pre_task4
printf "PRE_OLDEST_TICK=%llu\n", `$pre_oldest_tick
printf "PRE_NEWEST_TICK=%llu\n", `$pre_newest_tick
printf "QUERY1_TICK=%llu\n", `$query1_tick
printf "QUERY1_VECTOR_COUNT=%u\n", `$query1_vector_count
printf "QUERY1_BEFORE_TICK_COUNT=%u\n", `$query1_before_tick_count
printf "QUERY1_REASON_VECTOR_COUNT=%u\n", `$query1_reason_vector_count
printf "QUERY2_TICK=%llu\n", `$query2_tick
printf "QUERY2_VECTOR_COUNT=%u\n", `$query2_vector_count
printf "QUERY2_BEFORE_TICK_COUNT=%u\n", `$query2_before_tick_count
printf "QUERY2_REASON_VECTOR_COUNT=%u\n", `$query2_reason_vector_count
printf "QUERY3_TICK=%llu\n", `$query3_tick
printf "QUERY3_VECTOR_COUNT=%u\n", `$query3_vector_count
printf "QUERY3_BEFORE_TICK_COUNT=%u\n", `$query3_before_tick_count
printf "QUERY3_REASON_VECTOR_COUNT=%u\n", `$query3_reason_vector_count
printf "TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
printf "WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
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
$hitAfterWakeQueueCountSnapshot = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$preLen = $null
$preTask0 = $null
$preTask1 = $null
$preTask2 = $null
$preTask3 = $null
$preTask4 = $null
$preOldestTick = $null
$preNewestTick = $null
$query1Tick = $null
$query1VectorCount = $null
$query1BeforeTickCount = $null
$query1ReasonVectorCount = $null
$query2Tick = $null
$query2VectorCount = $null
$query2BeforeTickCount = $null
$query2ReasonVectorCount = $null
$query3Tick = $null
$query3VectorCount = $null
$query3BeforeTickCount = $null
$query3ReasonVectorCount = $null
$timerPendingWakeCount = $null
$wakeQueueCount = $null
$wake0Seq = $null
$wake0TaskId = $null
$wake0TimerId = $null
$wake0Reason = $null
$wake0Vector = $null
$wake0Tick = $null

if (Test-Path $gdbStdout) {
    $gdbOutput = [string](Get-Content -Path $gdbStdout -Raw)
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfterWakeQueueCountSnapshot = $gdbOutput.Contains("AFTER_WAKE_QUEUE_COUNT_SNAPSHOT")
    $ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_SEQ"
    $preLen = Extract-IntValue -Text $gdbOutput -Name "PRE_LEN"
    $preTask0 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK0"
    $preTask1 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK1"
    $preTask2 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK2"
    $preTask3 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK3"
    $preTask4 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK4"
    $preOldestTick = Extract-IntValue -Text $gdbOutput -Name "PRE_OLDEST_TICK"
    $preNewestTick = Extract-IntValue -Text $gdbOutput -Name "PRE_NEWEST_TICK"
    $query1Tick = Extract-IntValue -Text $gdbOutput -Name "QUERY1_TICK"
    $query1VectorCount = Extract-IntValue -Text $gdbOutput -Name "QUERY1_VECTOR_COUNT"
    $query1BeforeTickCount = Extract-IntValue -Text $gdbOutput -Name "QUERY1_BEFORE_TICK_COUNT"
    $query1ReasonVectorCount = Extract-IntValue -Text $gdbOutput -Name "QUERY1_REASON_VECTOR_COUNT"
    $query2Tick = Extract-IntValue -Text $gdbOutput -Name "QUERY2_TICK"
    $query2VectorCount = Extract-IntValue -Text $gdbOutput -Name "QUERY2_VECTOR_COUNT"
    $query2BeforeTickCount = Extract-IntValue -Text $gdbOutput -Name "QUERY2_BEFORE_TICK_COUNT"
    $query2ReasonVectorCount = Extract-IntValue -Text $gdbOutput -Name "QUERY2_REASON_VECTOR_COUNT"
    $query3Tick = Extract-IntValue -Text $gdbOutput -Name "QUERY3_TICK"
    $query3VectorCount = Extract-IntValue -Text $gdbOutput -Name "QUERY3_VECTOR_COUNT"
    $query3BeforeTickCount = Extract-IntValue -Text $gdbOutput -Name "QUERY3_BEFORE_TICK_COUNT"
    $query3ReasonVectorCount = Extract-IntValue -Text $gdbOutput -Name "QUERY3_REASON_VECTOR_COUNT"
    $timerPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_PENDING_WAKE_COUNT"
    $wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
    $wake0Seq = Extract-IntValue -Text $gdbOutput -Name "WAKE0_SEQ"
    $wake0TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TASK_ID"
    $wake0TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TIMER_ID"
    $wake0Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE0_REASON"
    $wake0Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE0_VECTOR"
    $wake0Tick = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TICK"
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
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE_QUEUE_COUNT_ADDR=0x$wakeQueueCountAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_TIMER_STATE_ADDR=0x$timerStateAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_HIT_AFTER_COUNT_SNAPSHOT=$hitAfterWakeQueueCountSnapshot"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_LEN=$preLen"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_TASK0=$preTask0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_TASK1=$preTask1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_TASK2=$preTask2"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_TASK3=$preTask3"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_TASK4=$preTask4"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_OLDEST_TICK=$preOldestTick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_PRE_NEWEST_TICK=$preNewestTick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_TICK=$query1Tick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_VECTOR_COUNT=$query1VectorCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_BEFORE_TICK_COUNT=$query1BeforeTickCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY1_REASON_VECTOR_COUNT=$query1ReasonVectorCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_TICK=$query2Tick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_VECTOR_COUNT=$query2VectorCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_BEFORE_TICK_COUNT=$query2BeforeTickCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY2_REASON_VECTOR_COUNT=$query2ReasonVectorCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_TICK=$query3Tick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_VECTOR_COUNT=$query3VectorCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_BEFORE_TICK_COUNT=$query3BeforeTickCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QUERY3_REASON_VECTOR_COUNT=$query3ReasonVectorCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_TIMER_PENDING_WAKE_COUNT=$timerPendingWakeCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE_TIMED_OUT=$timedOut"

$probePassed = $hitStart -and
    $hitAfterWakeQueueCountSnapshot -and
    (-not $timedOut) -and
    ($ack -eq 19) -and
    ($lastOpcode -eq $schedulerWakeTaskOpcode) -and
    ($lastResult -eq $resultOk) -and
    ($mailboxOpcode -eq $schedulerWakeTaskOpcode) -and
    ($mailboxSeq -eq 19) -and
    ($preLen -eq 5) -and
    ($preTask0 -eq $taskIdTimer) -and
    ($preTask1 -eq $taskIdInterruptA1) -and
    ($preTask2 -eq $taskIdInterruptA2) -and
    ($preTask3 -eq $taskIdInterruptB) -and
    ($preTask4 -eq $taskIdManual) -and
    ($preNewestTick -ge $preOldestTick) -and
    ($query1Tick -ge $preOldestTick) -and
    ($query2Tick -ge $query1Tick) -and
    ($query3Tick -ge $query2Tick) -and
    ($query1VectorCount -eq 2) -and
    ($query1BeforeTickCount -eq 2) -and
    ($query1ReasonVectorCount -eq 2) -and
    ($query2VectorCount -eq 1) -and
    ($query2BeforeTickCount -eq 4) -and
    ($query2ReasonVectorCount -eq 1) -and
    ($query3VectorCount -eq 1) -and
    ($query3BeforeTickCount -eq 5) -and
    ($query3ReasonVectorCount -eq 0) -and
    ($timerPendingWakeCount -eq $wakeQueueCount) -and
    ($wakeQueueCount -eq 5) -and
    ($wake0Seq -eq 1) -and
    ($wake0TaskId -eq $taskIdTimer) -and
    ($wake0TimerId -gt 0) -and
    ($wake0Reason -eq $wakeReasonTimer) -and
    ($wake0Vector -eq 0) -and
    ($wake0Tick -eq $preOldestTick) -and
    ($ticks -ge $query3Tick)

Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_COUNT_SNAPSHOT_PROBE=$($(if ($probePassed) { 'pass' } else { 'fail' }))"
if (-not $probePassed) {
    if (Test-Path $gdbStderr) {
        Get-Content -Path $gdbStderr | Write-Error
    }
    exit 1
}








