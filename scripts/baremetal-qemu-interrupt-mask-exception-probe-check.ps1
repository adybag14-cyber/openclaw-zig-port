param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$resetExceptionCountersOpcode = 11
$clearInterruptHistoryOpcode = 14
$clearExceptionHistoryOpcode = 13
$interruptMaskClearAllOpcode = 64
$interruptMaskApplyProfileOpcode = 66
$taskCreateOpcode = 27
$taskWaitInterruptOpcode = 57
$triggerInterruptOpcode = 7
$triggerExceptionOpcode = 12

$taskBudget = 11
$taskPriority = 4
$maskedVector = 200
$exceptionVector = 13
$exceptionCode = 51966
$interruptMaskProfileExternalAll = 1
$waitInterruptAnyVector = 65535

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

$interruptStateLastInterruptVectorOffset = 2
$interruptStateInterruptCountOffset = 16
$interruptStateLastExceptionVectorOffset = 24
$interruptStateExceptionCountOffset = 32
$interruptStateLastExceptionCodeOffset = 40
$interruptStateExceptionHistoryLenOffset = 48
$interruptStateInterruptHistoryLenOffset = 56

$interruptEventSeqOffset = 0
$interruptEventVectorOffset = 4
$interruptEventIsExceptionOffset = 5
$interruptEventCodeOffset = 8
$interruptEventInterruptCountOffset = 16
$interruptEventExceptionCountOffset = 24

$exceptionEventSeqOffset = 0
$exceptionEventVectorOffset = 4
$exceptionEventCodeOffset = 8
$exceptionEventInterruptCountOffset = 16
$exceptionEventExceptionCountOffset = 24

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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-interrupt-mask-exception-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-interrupt-mask-exception-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-interrupt-mask-exception-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-interrupt-mask-exception-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")
$gdbScript = Join-Path $releaseDir "qemu-interrupt-mask-exception-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-interrupt-mask-exception-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-interrupt-mask-exception-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-interrupt-mask-exception-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-interrupt-mask-exception-probe-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-interrupt-mask-exception-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for interrupt-mask-exception probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for interrupt-mask-exception probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for interrupt-mask-exception probe PVH artifact failed with exit code $LASTEXITCODE"
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
$interruptStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_state$' -SymbolName "baremetal.x86_bootstrap.interrupt_state"
$interruptMaskAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_mask$' -SymbolName "baremetal.x86_bootstrap.interrupt_mask"
$interruptMaskProfileAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_mask_profile$' -SymbolName "baremetal.x86_bootstrap.interrupt_mask_profile"
$interruptMaskedCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_masked_count$' -SymbolName "baremetal.x86_bootstrap.interrupt_masked_count"
$maskedInterruptIgnoredCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.masked_interrupt_ignored_count$' -SymbolName "baremetal.x86_bootstrap.masked_interrupt_ignored_count"
$interruptMaskIgnoredVectorCountsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_mask_ignored_vector_counts$' -SymbolName "baremetal.x86_bootstrap.interrupt_mask_ignored_vector_counts"
$lastMaskedInterruptVectorAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.last_masked_interrupt_vector$' -SymbolName "baremetal.x86_bootstrap.last_masked_interrupt_vector"
$interruptHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_history$' -SymbolName "baremetal.x86_bootstrap.interrupt_history"
$exceptionHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.exception_history$' -SymbolName "baremetal.x86_bootstrap.exception_history"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetInterruptCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetExceptionCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $clearInterruptHistoryOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $clearExceptionHistoryOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskClearAllOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskApplyProfileOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptMaskProfileExternalAll
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $waitInterruptAnyVector
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $maskedVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11
    printf "TASK0_STATE_AFTER_MASK=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    printf "WAKE_QUEUE_COUNT_AFTER_MASK=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
    printf "MASK_IGNORED_AFTER_MASK=%llu\n", *(unsigned long long*)(0x$maskedInterruptIgnoredCountAddress)
    printf "MASKED_VECTOR_200_STATE=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$maskedVector)
    printf "MASKED_VECTOR_13_STATE=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$exceptionVector)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerExceptionOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $exceptionVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $exceptionCode
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12
    set `$stage = 13
  end
  continue
end
printf "AFTER_INTERRUPT_MASK_EXCEPTION\n"
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
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
printf "INTERRUPT_MASK_PROFILE=%u\n", *(unsigned char*)(0x$interruptMaskProfileAddress)
printf "INTERRUPT_MASKED_COUNT=%u\n", *(unsigned int*)(0x$interruptMaskedCountAddress)
printf "MASKED_INTERRUPT_IGNORED_COUNT=%llu\n", *(unsigned long long*)(0x$maskedInterruptIgnoredCountAddress)
printf "MASKED_VECTOR_200_IGNORED=%llu\n", *(unsigned long long*)(0x$interruptMaskIgnoredVectorCountsAddress+1600)
printf "LAST_MASKED_INTERRUPT_VECTOR=%u\n", *(unsigned char*)(0x$lastMaskedInterruptVectorAddress)
printf "INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
printf "LAST_INTERRUPT_VECTOR=%u\n", *(unsigned char*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset)
printf "EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset)
printf "LAST_EXCEPTION_VECTOR=%u\n", *(unsigned char*)(0x$interruptStateAddress+$interruptStateLastExceptionVectorOffset)
printf "LAST_EXCEPTION_CODE=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateLastExceptionCodeOffset)
printf "INTERRUPT_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset)
printf "EXCEPTION_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset)
printf "INTERRUPT_HISTORY0_SEQ=%u\n", *(unsigned int*)(0x$interruptHistoryAddress+$interruptEventSeqOffset)
printf "INTERRUPT_HISTORY0_VECTOR=%u\n", *(unsigned char*)(0x$interruptHistoryAddress+$interruptEventVectorOffset)
printf "INTERRUPT_HISTORY0_IS_EXCEPTION=%u\n", *(unsigned char*)(0x$interruptHistoryAddress+$interruptEventIsExceptionOffset)
printf "INTERRUPT_HISTORY0_CODE=%llu\n", *(unsigned long long*)(0x$interruptHistoryAddress+$interruptEventCodeOffset)
printf "INTERRUPT_HISTORY0_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptHistoryAddress+$interruptEventInterruptCountOffset)
printf "INTERRUPT_HISTORY0_EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$interruptHistoryAddress+$interruptEventExceptionCountOffset)
printf "EXCEPTION_HISTORY0_SEQ=%u\n", *(unsigned int*)(0x$exceptionHistoryAddress+$exceptionEventSeqOffset)
printf "EXCEPTION_HISTORY0_VECTOR=%u\n", *(unsigned char*)(0x$exceptionHistoryAddress+$exceptionEventVectorOffset)
printf "EXCEPTION_HISTORY0_CODE=%llu\n", *(unsigned long long*)(0x$exceptionHistoryAddress+$exceptionEventCodeOffset)
printf "EXCEPTION_HISTORY0_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$exceptionHistoryAddress+$exceptionEventInterruptCountOffset)
printf "EXCEPTION_HISTORY0_EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$exceptionHistoryAddress+$exceptionEventExceptionCountOffset)
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
$qemuArgs = @("-kernel", $artifact, "-nographic", "-no-reboot", "-no-shutdown", "-serial", "none", "-monitor", "none", "-S", "-gdb", "tcp::$GdbPort")
$qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
Start-Sleep -Milliseconds 700
$gdbArgs = @("-q", "-batch", "-x", $gdbScript)
$gdbProc = Start-Process -FilePath $gdb -ArgumentList $gdbArgs -PassThru -NoNewWindow -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr
$timedOut = $false
try {
    $null = Wait-Process -Id $gdbProc.Id -Timeout $TimeoutSeconds -ErrorAction Stop
} catch {
    $timedOut = $true
    try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
} finally {
    try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

$hitStart = $false
$hitAfterInterruptMaskException = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$task0StateAfterMask = $null
$wakeQueueCountAfterMask = $null
$maskIgnoredAfterMask = $null
$maskedVector200State = $null
$maskedVector13State = $null
$schedulerTaskCount = $null
$task0Id = $null
$task0State = $null
$task0Priority = $null
$task0RunCount = $null
$task0Budget = $null
$task0BudgetRemaining = $null
$wakeQueueCount = $null
$interruptMaskProfile = $null
$interruptMaskedCount = $null
$maskedInterruptIgnoredCount = $null
$maskedVector200Ignored = $null
$lastMaskedInterruptVector = $null
$interruptCount = $null
$lastInterruptVector = $null
$exceptionCount = $null
$lastExceptionVector = $null
$lastExceptionCode = $null
$interruptHistoryLen = $null
$exceptionHistoryLen = $null
$interruptHistory0Seq = $null
$interruptHistory0Vector = $null
$interruptHistory0IsException = $null
$interruptHistory0Code = $null
$interruptHistory0InterruptCount = $null
$interruptHistory0ExceptionCount = $null
$exceptionHistory0Seq = $null
$exceptionHistory0Vector = $null
$exceptionHistory0Code = $null
$exceptionHistory0InterruptCount = $null
$exceptionHistory0ExceptionCount = $null
$wake0Seq = $null
$wake0TaskId = $null
$wake0TimerId = $null
$wake0Reason = $null
$wake0Vector = $null
$wake0Tick = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterInterruptMaskException = $out -match "AFTER_INTERRUPT_MASK_EXCEPTION"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $task0StateAfterMask = Extract-IntValue -Text $out -Name "TASK0_STATE_AFTER_MASK"
    $wakeQueueCountAfterMask = Extract-IntValue -Text $out -Name "WAKE_QUEUE_COUNT_AFTER_MASK"
    $maskIgnoredAfterMask = Extract-IntValue -Text $out -Name "MASK_IGNORED_AFTER_MASK"
    $maskedVector200State = Extract-IntValue -Text $out -Name "MASKED_VECTOR_200_STATE"
    $maskedVector13State = Extract-IntValue -Text $out -Name "MASKED_VECTOR_13_STATE"
    $schedulerTaskCount = Extract-IntValue -Text $out -Name "SCHED_TASK_COUNT"
    $task0Id = Extract-IntValue -Text $out -Name "TASK0_ID"
    $task0State = Extract-IntValue -Text $out -Name "TASK0_STATE"
    $task0Priority = Extract-IntValue -Text $out -Name "TASK0_PRIORITY"
    $task0RunCount = Extract-IntValue -Text $out -Name "TASK0_RUN_COUNT"
    $task0Budget = Extract-IntValue -Text $out -Name "TASK0_BUDGET"
    $task0BudgetRemaining = Extract-IntValue -Text $out -Name "TASK0_BUDGET_REMAINING"
    $wakeQueueCount = Extract-IntValue -Text $out -Name "WAKE_QUEUE_COUNT"
    $interruptMaskProfile = Extract-IntValue -Text $out -Name "INTERRUPT_MASK_PROFILE"
    $interruptMaskedCount = Extract-IntValue -Text $out -Name "INTERRUPT_MASKED_COUNT"
    $maskedInterruptIgnoredCount = Extract-IntValue -Text $out -Name "MASKED_INTERRUPT_IGNORED_COUNT"
    $maskedVector200Ignored = Extract-IntValue -Text $out -Name "MASKED_VECTOR_200_IGNORED"
    $lastMaskedInterruptVector = Extract-IntValue -Text $out -Name "LAST_MASKED_INTERRUPT_VECTOR"
    $interruptCount = Extract-IntValue -Text $out -Name "INTERRUPT_COUNT"
    $lastInterruptVector = Extract-IntValue -Text $out -Name "LAST_INTERRUPT_VECTOR"
    $exceptionCount = Extract-IntValue -Text $out -Name "EXCEPTION_COUNT"
    $lastExceptionVector = Extract-IntValue -Text $out -Name "LAST_EXCEPTION_VECTOR"
    $lastExceptionCode = Extract-IntValue -Text $out -Name "LAST_EXCEPTION_CODE"
    $interruptHistoryLen = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY_LEN"
    $exceptionHistoryLen = Extract-IntValue -Text $out -Name "EXCEPTION_HISTORY_LEN"
    $interruptHistory0Seq = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_SEQ"
    $interruptHistory0Vector = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_VECTOR"
    $interruptHistory0IsException = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_IS_EXCEPTION"
    $interruptHistory0Code = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_CODE"
    $interruptHistory0InterruptCount = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_INTERRUPT_COUNT"
    $interruptHistory0ExceptionCount = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_EXCEPTION_COUNT"
    $exceptionHistory0Seq = Extract-IntValue -Text $out -Name "EXCEPTION_HISTORY0_SEQ"
    $exceptionHistory0Vector = Extract-IntValue -Text $out -Name "EXCEPTION_HISTORY0_VECTOR"
    $exceptionHistory0Code = Extract-IntValue -Text $out -Name "EXCEPTION_HISTORY0_CODE"
    $exceptionHistory0InterruptCount = Extract-IntValue -Text $out -Name "EXCEPTION_HISTORY0_INTERRUPT_COUNT"
    $exceptionHistory0ExceptionCount = Extract-IntValue -Text $out -Name "EXCEPTION_HISTORY0_EXCEPTION_COUNT"
    $wake0Seq = Extract-IntValue -Text $out -Name "WAKE0_SEQ"
    $wake0TaskId = Extract-IntValue -Text $out -Name "WAKE0_TASK_ID"
    $wake0TimerId = Extract-IntValue -Text $out -Name "WAKE0_TIMER_ID"
    $wake0Reason = Extract-IntValue -Text $out -Name "WAKE0_REASON"
    $wake0Vector = Extract-IntValue -Text $out -Name "WAKE0_VECTOR"
    $wake0Tick = Extract-IntValue -Text $out -Name "WAKE0_TICK"
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
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_SCHEDULER_STATE_ADDR=0x$schedulerStateAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASKS_ADDR=0x$schedulerTasksAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_STATE_ADDR=0x$interruptStateAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_MASK_ADDR=0x$interruptMaskAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY_ADDR=0x$interruptHistoryAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY_ADDR=0x$exceptionHistoryAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_HIT_AFTER_INTERRUPT_MASK_EXCEPTION=$hitAfterInterruptMaskException"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASK0_STATE_AFTER_MASK=$task0StateAfterMask"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE_QUEUE_COUNT_AFTER_MASK=$wakeQueueCountAfterMask"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MASK_IGNORED_AFTER_MASK=$maskIgnoredAfterMask"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MASKED_VECTOR_200_STATE=$maskedVector200State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MASKED_VECTOR_13_STATE=$maskedVector13State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_SCHED_TASK_COUNT=$schedulerTaskCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASK0_STATE=$task0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASK0_PRIORITY=$task0Priority"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASK0_RUN_COUNT=$task0RunCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASK0_BUDGET=$task0Budget"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_MASK_PROFILE=$interruptMaskProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_MASKED_COUNT=$interruptMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MASKED_INTERRUPT_IGNORED_COUNT=$maskedInterruptIgnoredCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_MASKED_VECTOR_200_IGNORED=$maskedVector200Ignored"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_LAST_MASKED_INTERRUPT_VECTOR=$lastMaskedInterruptVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_COUNT=$interruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_COUNT=$exceptionCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_LAST_EXCEPTION_VECTOR=$lastExceptionVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_LAST_EXCEPTION_CODE=$lastExceptionCode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY_LEN=$interruptHistoryLen"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY_LEN=$exceptionHistoryLen"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_SEQ=$interruptHistory0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_VECTOR=$interruptHistory0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_IS_EXCEPTION=$interruptHistory0IsException"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_CODE=$interruptHistory0Code"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_INTERRUPT_COUNT=$interruptHistory0InterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_EXCEPTION_COUNT=$interruptHistory0ExceptionCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_SEQ=$exceptionHistory0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_VECTOR=$exceptionHistory0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_CODE=$exceptionHistory0Code"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_INTERRUPT_COUNT=$exceptionHistory0InterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_EXCEPTION_COUNT=$exceptionHistory0ExceptionCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and
    $hitAfterInterruptMaskException -and
    (-not $timedOut) -and
    $ack -eq 12 -and
    $lastOpcode -eq $triggerExceptionOpcode -and
    $lastResult -eq 0 -and
    $ticks -ge 8 -and
    $mailboxOpcode -eq $triggerExceptionOpcode -and
    $mailboxSeq -eq 12 -and
    $task0StateAfterMask -eq 6 -and
    $wakeQueueCountAfterMask -eq 0 -and
    $maskIgnoredAfterMask -eq 1 -and
    $maskedVector200State -eq 1 -and
    $maskedVector13State -eq 0 -and
    $schedulerTaskCount -eq 1 -and
    $task0Id -eq 1 -and
    $task0State -eq 1 -and
    $task0Priority -eq $taskPriority -and
    $task0RunCount -eq 0 -and
    $task0Budget -eq $taskBudget -and
    $task0BudgetRemaining -eq $taskBudget -and
    $wakeQueueCount -eq 1 -and
    $interruptMaskProfile -eq $interruptMaskProfileExternalAll -and
    $interruptMaskedCount -eq 224 -and
    $maskedInterruptIgnoredCount -eq 1 -and
    $maskedVector200Ignored -eq 1 -and
    $lastMaskedInterruptVector -eq $maskedVector -and
    $interruptCount -eq 1 -and
    $lastInterruptVector -eq $exceptionVector -and
    $exceptionCount -eq 1 -and
    $lastExceptionVector -eq $exceptionVector -and
    $lastExceptionCode -eq $exceptionCode -and
    $interruptHistoryLen -eq 1 -and
    $exceptionHistoryLen -eq 1 -and
    $interruptHistory0Seq -eq 1 -and
    $interruptHistory0Vector -eq $exceptionVector -and
    $interruptHistory0IsException -eq 1 -and
    $interruptHistory0Code -eq $exceptionCode -and
    $interruptHistory0InterruptCount -eq 1 -and
    $interruptHistory0ExceptionCount -eq 1 -and
    $exceptionHistory0Seq -eq 1 -and
    $exceptionHistory0Vector -eq $exceptionVector -and
    $exceptionHistory0Code -eq $exceptionCode -and
    $exceptionHistory0InterruptCount -eq 1 -and
    $exceptionHistory0ExceptionCount -eq 1 -and
    $wake0Seq -eq 1 -and
    $wake0TaskId -eq 1 -and
    $wake0TimerId -eq 0 -and
    $wake0Reason -eq 2 -and
    $wake0Vector -eq $exceptionVector -and
    $wake0Tick -ge 1
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE=fail"
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

