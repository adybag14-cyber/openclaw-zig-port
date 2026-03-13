param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1244
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$clearInterruptHistoryOpcode = 14
$interruptMaskClearAllOpcode = 64
$interruptMaskSetOpcode = 63
$interruptMaskResetIgnoredCountsOpcode = 65
$interruptMaskApplyProfileOpcode = 66
$taskCreateOpcode = 27
$taskWaitInterruptOpcode = 57
$triggerInterruptOpcode = 7

$taskBudget = 11
$taskPriority = 4
$maskedVector = 200
$secondaryMaskedVector = 201
$unmaskedVectorBoundaryLow = 63
$maskedVectorBoundaryHigh = 64
$invalidProfile = 9
$interruptMaskProfileNone = 0
$interruptMaskProfileExternalAll = 1
$interruptMaskProfileExternalHigh = 2
$interruptMaskProfileCustom = 255
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

$maskedVectorIgnoredOffset = $maskedVector * 8
$secondaryMaskedVectorIgnoredOffset = $secondaryMaskedVector * 8
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

    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)$'
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-interrupt-mask-control-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-interrupt-mask-control-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-interrupt-mask-control-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-interrupt-mask-control-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-interrupt-mask-control-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-interrupt-mask-control-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-interrupt-mask-control-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-interrupt-mask-control-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-interrupt-mask-control-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-interrupt-mask-control-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for interrupt-mask-control probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for interrupt-mask-control probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for interrupt-mask-control probe PVH artifact failed with exit code $LASTEXITCODE"
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $clearInterruptHistoryOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskClearAllOpcode
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $waitInterruptAnyVector
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskSetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $maskedVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 1
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $maskedVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9
    printf "SET_MASKED_TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    printf "SET_MASKED_WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
    printf "SET_MASKED_IGNORED_COUNT=%llu\n", *(unsigned long long*)(0x$maskedInterruptIgnoredCountAddress)
    printf "SET_MASKED_MASKED_200=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$maskedVector)
    printf "SET_MASKED_PROFILE=%u\n", *(unsigned char*)(0x$interruptMaskProfileAddress)
    printf "SET_MASKED_MASKED_COUNT=%u\n", *(unsigned int*)(0x$interruptMaskedCountAddress)
    printf "SET_MASKED_LAST_MASKED_VECTOR=%u\n", *(unsigned char*)(0x$lastMaskedInterruptVectorAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskSetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $maskedVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
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
    printf "UNMASKED_TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    printf "UNMASKED_WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
    printf "UNMASKED_WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
    printf "UNMASKED_WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    printf "UNMASKED_PROFILE=%u\n", *(unsigned char*)(0x$interruptMaskProfileAddress)
    printf "UNMASKED_MASKED_COUNT=%u\n", *(unsigned int*)(0x$interruptMaskedCountAddress)
    printf "UNMASKED_MASKED_200=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$maskedVector)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskSetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 300
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 1
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12
    printf "INVALID_VECTOR_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "INVALID_VECTOR_CURRENT_PROFILE=%u\n", *(unsigned char*)(0x$interruptMaskProfileAddress)
    printf "INVALID_VECTOR_CURRENT_MASKED_COUNT=%u\n", *(unsigned int*)(0x$interruptMaskedCountAddress)
    printf "INVALID_VECTOR_CURRENT_MASKED_200=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$maskedVector)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskSetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $maskedVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 2
    set `$stage = 13
  end
  continue
end
if `$stage == 13
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 13
    printf "INVALID_STATE_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "INVALID_STATE_CURRENT_PROFILE=%u\n", *(unsigned char*)(0x$interruptMaskProfileAddress)
    printf "INVALID_STATE_CURRENT_MASKED_COUNT=%u\n", *(unsigned int*)(0x$interruptMaskedCountAddress)
    printf "INVALID_STATE_CURRENT_MASKED_200=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$maskedVector)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskSetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 14
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $secondaryMaskedVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 1
    set `$stage = 14
  end
  continue
end
if `$stage == 14
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 14
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 15
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $secondaryMaskedVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 15
  end
  continue
end
if `$stage == 15
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 15
    printf "SECONDARY_PROFILE=%u\n", *(unsigned char*)(0x$interruptMaskProfileAddress)
    printf "SECONDARY_MASKED_COUNT=%u\n", *(unsigned int*)(0x$interruptMaskedCountAddress)
    printf "SECONDARY_MASKED_201=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$secondaryMaskedVector)
    printf "SECONDARY_IGNORED_COUNT=%llu\n", *(unsigned long long*)(0x$maskedInterruptIgnoredCountAddress)
    printf "SECONDARY_IGNORED_200=%llu\n", *(unsigned long long*)(0x$interruptMaskIgnoredVectorCountsAddress+$maskedVectorIgnoredOffset)
    printf "SECONDARY_IGNORED_201=%llu\n", *(unsigned long long*)(0x$interruptMaskIgnoredVectorCountsAddress+$secondaryMaskedVectorIgnoredOffset)
    printf "SECONDARY_LAST_MASKED_VECTOR=%u\n", *(unsigned char*)(0x$lastMaskedInterruptVectorAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskResetIgnoredCountsOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 16
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 16
  end
  continue
end
if `$stage == 16
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 16
    printf "RESET_IGNORED_COUNT=%llu\n", *(unsigned long long*)(0x$maskedInterruptIgnoredCountAddress)
    printf "RESET_IGNORED_200=%llu\n", *(unsigned long long*)(0x$interruptMaskIgnoredVectorCountsAddress+$maskedVectorIgnoredOffset)
    printf "RESET_IGNORED_201=%llu\n", *(unsigned long long*)(0x$interruptMaskIgnoredVectorCountsAddress+$secondaryMaskedVectorIgnoredOffset)
    printf "RESET_LAST_MASKED_VECTOR=%u\n", *(unsigned char*)(0x$lastMaskedInterruptVectorAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $interruptMaskClearAllOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 17
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 17
  end
  continue
end
if `$stage == 17
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 17
    set `$stage = 18
  end
  continue
end
printf "AFTER_INTERRUPT_MASK_CONTROL\n"
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
printf "MASKED_200=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$maskedVector)
printf "MASKED_201=%u\n", *(unsigned char*)(0x$interruptMaskAddress+$secondaryMaskedVector)
printf "MASKED_INTERRUPT_IGNORED_COUNT=%llu\n", *(unsigned long long*)(0x$maskedInterruptIgnoredCountAddress)
printf "MASKED_VECTOR_200_IGNORED=%llu\n", *(unsigned long long*)(0x$interruptMaskIgnoredVectorCountsAddress+$maskedVectorIgnoredOffset)
printf "MASKED_VECTOR_201_IGNORED=%llu\n", *(unsigned long long*)(0x$interruptMaskIgnoredVectorCountsAddress+$secondaryMaskedVectorIgnoredOffset)
printf "LAST_MASKED_INTERRUPT_VECTOR=%u\n", *(unsigned char*)(0x$lastMaskedInterruptVectorAddress)
printf "INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
printf "LAST_INTERRUPT_VECTOR=%u\n", *(unsigned char*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset)
printf "INTERRUPT_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset)
printf "INTERRUPT_HISTORY0_SEQ=%u\n", *(unsigned int*)(0x$interruptHistoryAddress+$interruptEventSeqOffset)
printf "INTERRUPT_HISTORY0_VECTOR=%u\n", *(unsigned char*)(0x$interruptHistoryAddress+$interruptEventVectorOffset)
printf "INTERRUPT_HISTORY0_IS_EXCEPTION=%u\n", *(unsigned char*)(0x$interruptHistoryAddress+$interruptEventIsExceptionOffset)
printf "INTERRUPT_HISTORY0_CODE=%llu\n", *(unsigned long long*)(0x$interruptHistoryAddress+$interruptEventCodeOffset)
printf "INTERRUPT_HISTORY0_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptHistoryAddress+$interruptEventInterruptCountOffset)
printf "INTERRUPT_HISTORY0_EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$interruptHistoryAddress+$interruptEventExceptionCountOffset)
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
$hitAfterInterruptMaskProfile = $false
$hitAfterInterruptMaskControl = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$setMaskedTask0State = $null
$setMaskedWakeQueueCount = $null
$setMaskedIgnoredCount = $null
$setMaskedMasked200 = $null
$setMaskedProfile = $null
$setMaskedMaskedCount = $null
$setMaskedLastMaskedVector = $null
$unmaskedTask0State = $null
$unmaskedWakeQueueCount = $null
$unmaskedWake0Vector = $null
$unmaskedWake0Reason = $null
$unmaskedProfile = $null
$unmaskedMaskedCount = $null
$unmaskedMasked200 = $null
$invalidVectorResult = $null
$invalidVectorCurrentProfile = $null
$invalidVectorCurrentMaskedCount = $null
$invalidVectorCurrentMasked200 = $null
$invalidStateResult = $null
$invalidStateCurrentProfile = $null
$invalidStateCurrentMaskedCount = $null
$invalidStateCurrentMasked200 = $null
$secondaryProfile = $null
$secondaryMaskedCount = $null
$secondaryMasked201 = $null
$secondaryIgnoredCount = $null
$secondaryIgnored200 = $null
$secondaryIgnored201 = $null
$secondaryLastMaskedVector = $null
$externalAllTask0State = $null
$externalAllWakeQueueCount = $null
$externalAllIgnoredCount = $null
$externalAllMasked200 = $null
$externalAllProfile = $null
$externalAllMaskedCount = $null
$unmaskTask0State = $null
$unmaskWakeQueueCount = $null
$unmaskWake0Vector = $null
$unmaskWake0Reason = $null
$unmaskProfile = $null
$unmaskMaskedCount = $null
$unmaskMasked200 = $null
$customProfile = $null
$customMaskedCount = $null
$customMasked201 = $null
$customIgnoredCount = $null
$customIgnored200 = $null
$customIgnored201 = $null
$customLastMaskedVector = $null
$resetIgnoredCount = $null
$resetIgnored200 = $null
$resetIgnored201 = $null
$resetLastMaskedVector = $null
$externalHighProfile = $null
$externalHighMaskedCount = $null
$externalHighMasked63 = $null
$externalHighMasked64 = $null
$invalidProfileResult = $null
$invalidProfileCurrent = $null
$noneProfile = $null
$noneMaskedCount = $null
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
$masked200 = $null
$masked201 = $null
$maskedInterruptIgnoredCount = $null
$maskedVector200Ignored = $null
$maskedVector201Ignored = $null
$lastMaskedInterruptVector = $null
$interruptCount = $null
$lastInterruptVector = $null
$interruptHistoryLen = $null
$interruptHistory0Seq = $null
$interruptHistory0Vector = $null
$interruptHistory0IsException = $null
$interruptHistory0Code = $null
$interruptHistory0InterruptCount = $null
$interruptHistory0ExceptionCount = $null
$wake0Seq = $null
$wake0TaskId = $null
$wake0TimerId = $null
$wake0Reason = $null
$wake0Vector = $null
$wake0Tick = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterInterruptMaskProfile = $out -match "AFTER_INTERRUPT_MASK_CONTROL"
    $hitAfterInterruptMaskControl = $hitAfterInterruptMaskProfile
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $setMaskedTask0State = Extract-IntValue -Text $out -Name "SET_MASKED_TASK0_STATE"
    $setMaskedWakeQueueCount = Extract-IntValue -Text $out -Name "SET_MASKED_WAKE_QUEUE_COUNT"
    $setMaskedIgnoredCount = Extract-IntValue -Text $out -Name "SET_MASKED_IGNORED_COUNT"
    $setMaskedMasked200 = Extract-IntValue -Text $out -Name "SET_MASKED_MASKED_200"
    $setMaskedProfile = Extract-IntValue -Text $out -Name "SET_MASKED_PROFILE"
    $setMaskedMaskedCount = Extract-IntValue -Text $out -Name "SET_MASKED_MASKED_COUNT"
    $setMaskedLastMaskedVector = Extract-IntValue -Text $out -Name "SET_MASKED_LAST_MASKED_VECTOR"
    $unmaskedTask0State = Extract-IntValue -Text $out -Name "UNMASKED_TASK0_STATE"
    $unmaskedWakeQueueCount = Extract-IntValue -Text $out -Name "UNMASKED_WAKE_QUEUE_COUNT"
    $unmaskedWake0Vector = Extract-IntValue -Text $out -Name "UNMASKED_WAKE0_VECTOR"
    $unmaskedWake0Reason = Extract-IntValue -Text $out -Name "UNMASKED_WAKE0_REASON"
    $unmaskedProfile = Extract-IntValue -Text $out -Name "UNMASKED_PROFILE"
    $unmaskedMaskedCount = Extract-IntValue -Text $out -Name "UNMASKED_MASKED_COUNT"
    $unmaskedMasked200 = Extract-IntValue -Text $out -Name "UNMASKED_MASKED_200"
    $invalidVectorResult = Extract-IntValue -Text $out -Name "INVALID_VECTOR_RESULT"
    $invalidVectorCurrentProfile = Extract-IntValue -Text $out -Name "INVALID_VECTOR_CURRENT_PROFILE"
    $invalidVectorCurrentMaskedCount = Extract-IntValue -Text $out -Name "INVALID_VECTOR_CURRENT_MASKED_COUNT"
    $invalidVectorCurrentMasked200 = Extract-IntValue -Text $out -Name "INVALID_VECTOR_CURRENT_MASKED_200"
    $invalidStateResult = Extract-IntValue -Text $out -Name "INVALID_STATE_RESULT"
    $invalidStateCurrentProfile = Extract-IntValue -Text $out -Name "INVALID_STATE_CURRENT_PROFILE"
    $invalidStateCurrentMaskedCount = Extract-IntValue -Text $out -Name "INVALID_STATE_CURRENT_MASKED_COUNT"
    $invalidStateCurrentMasked200 = Extract-IntValue -Text $out -Name "INVALID_STATE_CURRENT_MASKED_200"
    $secondaryProfile = Extract-IntValue -Text $out -Name "SECONDARY_PROFILE"
    $secondaryMaskedCount = Extract-IntValue -Text $out -Name "SECONDARY_MASKED_COUNT"
    $secondaryMasked201 = Extract-IntValue -Text $out -Name "SECONDARY_MASKED_201"
    $secondaryIgnoredCount = Extract-IntValue -Text $out -Name "SECONDARY_IGNORED_COUNT"
    $secondaryIgnored200 = Extract-IntValue -Text $out -Name "SECONDARY_IGNORED_200"
    $secondaryIgnored201 = Extract-IntValue -Text $out -Name "SECONDARY_IGNORED_201"
    $secondaryLastMaskedVector = Extract-IntValue -Text $out -Name "SECONDARY_LAST_MASKED_VECTOR"
    $externalAllTask0State = Extract-IntValue -Text $out -Name "EXTERNAL_ALL_TASK0_STATE"
    $externalAllWakeQueueCount = Extract-IntValue -Text $out -Name "EXTERNAL_ALL_WAKE_QUEUE_COUNT"
    $externalAllIgnoredCount = Extract-IntValue -Text $out -Name "EXTERNAL_ALL_IGNORED_COUNT"
    $externalAllMasked200 = Extract-IntValue -Text $out -Name "EXTERNAL_ALL_MASKED_200"
    $externalAllProfile = Extract-IntValue -Text $out -Name "EXTERNAL_ALL_PROFILE"
    $externalAllMaskedCount = Extract-IntValue -Text $out -Name "EXTERNAL_ALL_MASKED_COUNT"
    $unmaskTask0State = Extract-IntValue -Text $out -Name "UNMASK_TASK0_STATE"
    $unmaskWakeQueueCount = Extract-IntValue -Text $out -Name "UNMASK_WAKE_QUEUE_COUNT"
    $unmaskWake0Vector = Extract-IntValue -Text $out -Name "UNMASK_WAKE0_VECTOR"
    $unmaskWake0Reason = Extract-IntValue -Text $out -Name "UNMASK_WAKE0_REASON"
    $unmaskProfile = Extract-IntValue -Text $out -Name "UNMASK_PROFILE"
    $unmaskMaskedCount = Extract-IntValue -Text $out -Name "UNMASK_MASKED_COUNT"
    $unmaskMasked200 = Extract-IntValue -Text $out -Name "UNMASK_MASKED_200"
    $customProfile = Extract-IntValue -Text $out -Name "CUSTOM_PROFILE"
    $customMaskedCount = Extract-IntValue -Text $out -Name "CUSTOM_MASKED_COUNT"
    $customMasked201 = Extract-IntValue -Text $out -Name "CUSTOM_MASKED_201"
    $customIgnoredCount = Extract-IntValue -Text $out -Name "CUSTOM_IGNORED_COUNT"
    $customIgnored200 = Extract-IntValue -Text $out -Name "CUSTOM_IGNORED_200"
    $customIgnored201 = Extract-IntValue -Text $out -Name "CUSTOM_IGNORED_201"
    $customLastMaskedVector = Extract-IntValue -Text $out -Name "CUSTOM_LAST_MASKED_VECTOR"
    $resetIgnoredCount = Extract-IntValue -Text $out -Name "RESET_IGNORED_COUNT"
    $resetIgnored200 = Extract-IntValue -Text $out -Name "RESET_IGNORED_200"
    $resetIgnored201 = Extract-IntValue -Text $out -Name "RESET_IGNORED_201"
    $resetLastMaskedVector = Extract-IntValue -Text $out -Name "RESET_LAST_MASKED_VECTOR"
    $externalHighProfile = Extract-IntValue -Text $out -Name "EXTERNAL_HIGH_PROFILE"
    $externalHighMaskedCount = Extract-IntValue -Text $out -Name "EXTERNAL_HIGH_MASKED_COUNT"
    $externalHighMasked63 = Extract-IntValue -Text $out -Name "EXTERNAL_HIGH_MASKED_63"
    $externalHighMasked64 = Extract-IntValue -Text $out -Name "EXTERNAL_HIGH_MASKED_64"
    $invalidProfileResult = Extract-IntValue -Text $out -Name "INVALID_PROFILE_RESULT"
    $invalidProfileCurrent = Extract-IntValue -Text $out -Name "INVALID_PROFILE_CURRENT"
    $noneProfile = Extract-IntValue -Text $out -Name "NONE_PROFILE"
    $noneMaskedCount = Extract-IntValue -Text $out -Name "NONE_MASKED_COUNT"
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
    $masked200 = Extract-IntValue -Text $out -Name "MASKED_200"
    $masked201 = Extract-IntValue -Text $out -Name "MASKED_201"
    $maskedInterruptIgnoredCount = Extract-IntValue -Text $out -Name "MASKED_INTERRUPT_IGNORED_COUNT"
    $maskedVector200Ignored = Extract-IntValue -Text $out -Name "MASKED_VECTOR_200_IGNORED"
    $maskedVector201Ignored = Extract-IntValue -Text $out -Name "MASKED_VECTOR_201_IGNORED"
    $lastMaskedInterruptVector = Extract-IntValue -Text $out -Name "LAST_MASKED_INTERRUPT_VECTOR"
    $interruptCount = Extract-IntValue -Text $out -Name "INTERRUPT_COUNT"
    $lastInterruptVector = Extract-IntValue -Text $out -Name "LAST_INTERRUPT_VECTOR"
    $interruptHistoryLen = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY_LEN"
    $interruptHistory0Seq = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_SEQ"
    $interruptHistory0Vector = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_VECTOR"
    $interruptHistory0IsException = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_IS_EXCEPTION"
    $interruptHistory0Code = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_CODE"
    $interruptHistory0InterruptCount = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_INTERRUPT_COUNT"
    $interruptHistory0ExceptionCount = Extract-IntValue -Text $out -Name "INTERRUPT_HISTORY0_EXCEPTION_COUNT"
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
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SCHEDULER_STATE_ADDR=0x$schedulerStateAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TASKS_ADDR=0x$schedulerTasksAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_STATE_ADDR=0x$interruptStateAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_MASK_ADDR=0x$interruptMaskAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY_ADDR=0x$interruptHistoryAddress"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_HIT_AFTER_INTERRUPT_MASK_CONTROL=$hitAfterInterruptMaskControl"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SET_MASKED_TASK0_STATE=$setMaskedTask0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SET_MASKED_WAKE_QUEUE_COUNT=$setMaskedWakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SET_MASKED_IGNORED_COUNT=$setMaskedIgnoredCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SET_MASKED_MASKED_200=$setMaskedMasked200"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SET_MASKED_PROFILE=$setMaskedProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SET_MASKED_MASKED_COUNT=$setMaskedMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SET_MASKED_LAST_MASKED_VECTOR=$setMaskedLastMaskedVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASKED_TASK0_STATE=$unmaskedTask0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASKED_WAKE_QUEUE_COUNT=$unmaskedWakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASKED_WAKE0_VECTOR=$unmaskedWake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASKED_WAKE0_REASON=$unmaskedWake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_VECTOR_RESULT=$invalidVectorResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_VECTOR_CURRENT_PROFILE=$invalidVectorCurrentProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_VECTOR_CURRENT_MASKED_COUNT=$invalidVectorCurrentMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_VECTOR_CURRENT_MASKED_200=$invalidVectorCurrentMasked200"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_STATE_RESULT=$invalidStateResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_STATE_CURRENT_PROFILE=$invalidStateCurrentProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_STATE_CURRENT_MASKED_COUNT=$invalidStateCurrentMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_STATE_CURRENT_MASKED_200=$invalidStateCurrentMasked200"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SECONDARY_MASKED_COUNT=$secondaryMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SECONDARY_IGNORED_COUNT=$secondaryIgnoredCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_ALL_TASK0_STATE=$externalAllTask0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_ALL_WAKE_QUEUE_COUNT=$externalAllWakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_ALL_IGNORED_COUNT=$externalAllIgnoredCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_ALL_MASKED_200=$externalAllMasked200"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_ALL_PROFILE=$externalAllProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_ALL_MASKED_COUNT=$externalAllMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASK_TASK0_STATE=$unmaskTask0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASK_WAKE_QUEUE_COUNT=$unmaskWakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASK_WAKE0_VECTOR=$unmaskWake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASK_WAKE0_REASON=$unmaskWake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASK_PROFILE=$unmaskProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASK_MASKED_COUNT=$unmaskMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_UNMASK_MASKED_200=$unmaskMasked200"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_CUSTOM_PROFILE=$customProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_CUSTOM_MASKED_COUNT=$customMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_CUSTOM_MASKED_201=$customMasked201"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_CUSTOM_IGNORED_COUNT=$customIgnoredCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_CUSTOM_IGNORED_200=$customIgnored200"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_CUSTOM_IGNORED_201=$customIgnored201"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_CUSTOM_LAST_MASKED_VECTOR=$customLastMaskedVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_RESET_IGNORED_COUNT=$resetIgnoredCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_RESET_IGNORED_200=$resetIgnored200"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_RESET_IGNORED_201=$resetIgnored201"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_RESET_LAST_MASKED_VECTOR=$resetLastMaskedVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_HIGH_PROFILE=$externalHighProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_HIGH_MASKED_COUNT=$externalHighMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_HIGH_MASKED_63=$externalHighMasked63"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_EXTERNAL_HIGH_MASKED_64=$externalHighMasked64"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_PROFILE_RESULT=$invalidProfileResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INVALID_PROFILE_CURRENT=$invalidProfileCurrent"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_NONE_PROFILE=$noneProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_NONE_MASKED_COUNT=$noneMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_SCHED_TASK_COUNT=$schedulerTaskCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TASK0_STATE=$task0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TASK0_PRIORITY=$task0Priority"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TASK0_RUN_COUNT=$task0RunCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TASK0_BUDGET=$task0Budget"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_MASK_PROFILE=$interruptMaskProfile"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_MASKED_COUNT=$interruptMaskedCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MASKED_INTERRUPT_IGNORED_COUNT=$maskedInterruptIgnoredCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MASKED_VECTOR_200_IGNORED=$maskedVector200Ignored"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_MASKED_VECTOR_201_IGNORED=$maskedVector201Ignored"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_LAST_MASKED_INTERRUPT_VECTOR=$lastMaskedInterruptVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_COUNT=$interruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_LAST_INTERRUPT_VECTOR=$lastInterruptVector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY_LEN=$interruptHistoryLen"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY0_SEQ=$interruptHistory0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY0_VECTOR=$interruptHistory0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY0_IS_EXCEPTION=$interruptHistory0IsException"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY0_CODE=$interruptHistory0Code"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY0_INTERRUPT_COUNT=$interruptHistory0InterruptCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_INTERRUPT_HISTORY0_EXCEPTION_COUNT=$interruptHistory0ExceptionCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and
    $hitAfterInterruptMaskControl -and
    (-not $timedOut) -and
    $ack -eq 17 -and
    $lastOpcode -eq $interruptMaskClearAllOpcode -and
    $lastResult -eq 0 -and
    $ticks -ge 7 -and
    $mailboxOpcode -eq $interruptMaskClearAllOpcode -and
    $mailboxSeq -eq 17 -and
    $setMaskedTask0State -eq 6 -and
    $setMaskedWakeQueueCount -eq 0 -and
    $setMaskedIgnoredCount -eq 1 -and
    $setMaskedMasked200 -eq 1 -and
    $setMaskedProfile -eq $interruptMaskProfileCustom -and
    $setMaskedMaskedCount -eq 1 -and
    $setMaskedLastMaskedVector -eq $maskedVector -and
    $unmaskedTask0State -eq 1 -and
    $unmaskedWakeQueueCount -eq 1 -and
    $unmaskedWake0Vector -eq $maskedVector -and
    $unmaskedWake0Reason -eq 2 -and
    $unmaskedProfile -eq $interruptMaskProfileCustom -and
    $unmaskedMaskedCount -eq 0 -and
    $unmaskedMasked200 -eq 0 -and
    $invalidVectorResult -eq -22 -and
    $invalidVectorCurrentProfile -eq $interruptMaskProfileCustom -and
    $invalidVectorCurrentMaskedCount -eq 0 -and
    $invalidVectorCurrentMasked200 -eq 0 -and
    $invalidStateResult -eq -22 -and
    $invalidStateCurrentProfile -eq $interruptMaskProfileCustom -and
    $invalidStateCurrentMaskedCount -eq 0 -and
    $invalidStateCurrentMasked200 -eq 0 -and
    $secondaryProfile -eq $interruptMaskProfileCustom -and
    $secondaryMaskedCount -eq 1 -and
    $secondaryMasked201 -eq 1 -and
    $secondaryIgnoredCount -eq 2 -and
    $secondaryIgnored200 -eq 1 -and
    $secondaryIgnored201 -eq 1 -and
    $secondaryLastMaskedVector -eq $secondaryMaskedVector -and
    $resetIgnoredCount -eq 0 -and
    $resetIgnored200 -eq 0 -and
    $resetIgnored201 -eq 0 -and
    $resetLastMaskedVector -eq 0 -and
    $schedulerTaskCount -eq 1 -and
    $task0Id -eq 1 -and
    $task0State -eq 1 -and
    $task0Priority -eq $taskPriority -and
    $task0RunCount -eq 0 -and
    $task0Budget -eq $taskBudget -and
    $task0BudgetRemaining -eq $taskBudget -and
    $wakeQueueCount -eq 1 -and
    $interruptMaskProfile -eq $interruptMaskProfileNone -and
    $interruptMaskedCount -eq 0 -and
    $masked200 -eq 0 -and
    $masked201 -eq 0 -and
    $maskedInterruptIgnoredCount -eq 0 -and
    $maskedVector200Ignored -eq 0 -and
    $maskedVector201Ignored -eq 0 -and
    $lastMaskedInterruptVector -eq 0 -and
    $interruptCount -eq 1 -and
    $lastInterruptVector -eq $maskedVector -and
    $interruptHistoryLen -eq 1 -and
    $interruptHistory0Seq -eq 1 -and
    $interruptHistory0Vector -eq $maskedVector -and
    $interruptHistory0IsException -eq 0 -and
    $interruptHistory0Code -eq 0 -and
    $interruptHistory0InterruptCount -eq 1 -and
    $interruptHistory0ExceptionCount -eq 0 -and
    $wake0Seq -eq 1 -and
    $wake0TaskId -eq 1 -and
    $wake0TimerId -eq 0 -and
    $wake0Reason -eq 2 -and
    $wake0Vector -eq $maskedVector -and
    $wake0Tick -ge 1
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_INTERRUPT_MASK_CONTROL_PROBE=fail"
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



