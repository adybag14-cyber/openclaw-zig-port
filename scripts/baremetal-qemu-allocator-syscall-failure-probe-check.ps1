param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$allocatorResetOpcode = 31
$schedulerResetOpcode = 26
$syscallResetOpcode = 37
$resetCommandResultCountersOpcode = 23
$allocatorAllocOpcode = 32
$syscallRegisterOpcode = 34
$syscallSetFlagsOpcode = 40
$syscallInvokeOpcode = 36
$syscallDisableOpcode = 39

$invalidAlignSize = 4096
$invalidAlign = 3000
$validAlign = 4096
$syscallId = 9
$handlerToken = 48879
$blockedFlag = 1
$invokeArg = 4660

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$allocatorHeapSizeOffset = 8
$allocatorFreePagesOffset = 24
$allocatorAllocationCountOffset = 28
$allocatorBytesInUseOffset = 40

$commandResultOkCountOffset = 0
$commandResultInvalidCountOffset = 4
$commandResultNotSupportedCountOffset = 8
$commandResultOtherErrorCountOffset = 12
$commandResultTotalCountOffset = 16
$commandResultLastResultOffset = 24
$commandResultLastOpcodeOffset = 28
$commandResultLastSeqOffset = 32

$syscallStateEnabledOffset = 0
$syscallStateEntryCountOffset = 1
$syscallStateLastIdOffset = 4
$syscallStateDispatchCountOffset = 8
$syscallStateLastInvokeTickOffset = 16
$syscallStateLastResultOffset = 24

$syscallEntryIdOffset = 0
$syscallEntryStateOffset = 4
$syscallEntryFlagsOffset = 5
$syscallEntryTokenOffset = 8
$syscallEntryInvokeCountOffset = 16
$syscallEntryLastArgOffset = 24
$syscallEntryLastResultOffset = 32
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-allocator-syscall-failure-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-allocator-syscall-failure-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-allocator-syscall-failure-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-allocator-syscall-failure-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-allocator-syscall-failure-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-allocator-syscall-failure-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-allocator-syscall-failure-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-allocator-syscall-failure-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-allocator-syscall-failure-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-allocator-syscall-failure-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for allocator-syscall-failure probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for allocator-syscall-failure probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for allocator-syscall-failure probe PVH artifact failed with exit code $LASTEXITCODE"
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
$allocatorStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_state$' -SymbolName "baremetal_main.allocator_state"
$commandResultCountersAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_result_counters$' -SymbolName "baremetal_main.command_result_counters"
$syscallStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.syscall_state$' -SymbolName "baremetal_main.syscall_state"
$syscallEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.syscall_entries$' -SymbolName "baremetal_main.syscall_entries"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }
@"
set pagination off
set confirm off
set `$stage = 0
set `$heap_size = 0
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START\n"
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $allocatorResetOpcode
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetCommandResultCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $allocatorAllocOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $invalidAlignSize
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $invalidAlign
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    printf "INVALID_ALIGN_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    set `$heap_size = *(unsigned long long*)(0x$allocatorStateAddress+$allocatorHeapSizeOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $allocatorAllocOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$heap_size + $validAlign
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $validAlign
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6
    printf "NO_SPACE_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "ALLOCATOR_FREE_PAGES_AFTER_FAILURE=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorFreePagesOffset)
    printf "ALLOCATOR_ALLOCATION_COUNT_AFTER_FAILURE=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorAllocationCountOffset)
    printf "ALLOCATOR_BYTES_IN_USE_AFTER_FAILURE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorBytesInUseOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallRegisterOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $handlerToken
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallSetFlagsOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $blockedFlag
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallInvokeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $invokeArg
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9
    printf "BLOCKED_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallInvokeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $invokeArg
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11
    set `$stage = 12
  end
  continue
end
printf "AFTER_FAILURE_PATHS\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
printf "COMMAND_RESULT_OK_COUNT=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOkCountOffset)
printf "COMMAND_RESULT_INVALID_COUNT=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultInvalidCountOffset)
printf "COMMAND_RESULT_NOT_SUPPORTED_COUNT=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultNotSupportedCountOffset)
printf "COMMAND_RESULT_OTHER_ERROR_COUNT=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOtherErrorCountOffset)
printf "COMMAND_RESULT_TOTAL_COUNT=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultTotalCountOffset)
printf "COMMAND_RESULT_LAST_RESULT=%d\n", *(short*)(0x$commandResultCountersAddress+$commandResultLastResultOffset)
printf "COMMAND_RESULT_LAST_OPCODE=%u\n", *(unsigned short*)(0x$commandResultCountersAddress+$commandResultLastOpcodeOffset)
printf "COMMAND_RESULT_LAST_SEQ=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultLastSeqOffset)
printf "SYSCALL_ENABLED=%u\n", *(unsigned char*)(0x$syscallStateAddress+$syscallStateEnabledOffset)
printf "SYSCALL_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$syscallStateAddress+$syscallStateEntryCountOffset)
printf "SYSCALL_LAST_ID=%u\n", *(unsigned int*)(0x$syscallStateAddress+$syscallStateLastIdOffset)
printf "SYSCALL_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$syscallStateAddress+$syscallStateDispatchCountOffset)
printf "SYSCALL_LAST_INVOKE_TICK=%llu\n", *(unsigned long long*)(0x$syscallStateAddress+$syscallStateLastInvokeTickOffset)
printf "SYSCALL_LAST_RESULT=%lld\n", *(long long*)(0x$syscallStateAddress+$syscallStateLastResultOffset)
printf "SYSCALL_ENTRY0_ID=%u\n", *(unsigned int*)(0x$syscallEntriesAddress+$syscallEntryIdOffset)
printf "SYSCALL_ENTRY0_STATE=%u\n", *(unsigned char*)(0x$syscallEntriesAddress+$syscallEntryStateOffset)
printf "SYSCALL_ENTRY0_FLAGS=%u\n", *(unsigned char*)(0x$syscallEntriesAddress+$syscallEntryFlagsOffset)
printf "SYSCALL_ENTRY0_TOKEN=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryTokenOffset)
printf "SYSCALL_ENTRY0_INVOKE_COUNT=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryInvokeCountOffset)
printf "SYSCALL_ENTRY0_LAST_ARG=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryLastArgOffset)
printf "SYSCALL_ENTRY0_LAST_RESULT=%lld\n", *(long long*)(0x$syscallEntriesAddress+$syscallEntryLastResultOffset)
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
$hitAfterFailurePaths = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$invalidAlignResult = $null
$noSpaceResult = $null
$allocatorFreePagesAfterFailure = $null
$allocatorAllocationCountAfterFailure = $null
$allocatorBytesInUseAfterFailure = $null
$blockedResult = $null
$commandResultOkCount = $null
$commandResultInvalidCount = $null
$commandResultNotSupportedCount = $null
$commandResultOtherErrorCount = $null
$commandResultTotalCount = $null
$commandResultLastResult = $null
$commandResultLastOpcode = $null
$commandResultLastSeq = $null
$syscallEnabled = $null
$syscallEntryCount = $null
$syscallLastId = $null
$syscallDispatchCount = $null
$syscallLastInvokeTick = $null
$syscallLastResult = $null
$syscallEntry0Id = $null
$syscallEntry0State = $null
$syscallEntry0Flags = $null
$syscallEntry0Token = $null
$syscallEntry0InvokeCount = $null
$syscallEntry0LastArg = $null
$syscallEntry0LastResult = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterFailurePaths = $out -match "AFTER_FAILURE_PATHS"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $invalidAlignResult = Extract-IntValue -Text $out -Name "INVALID_ALIGN_RESULT"
    $noSpaceResult = Extract-IntValue -Text $out -Name "NO_SPACE_RESULT"
    $allocatorFreePagesAfterFailure = Extract-IntValue -Text $out -Name "ALLOCATOR_FREE_PAGES_AFTER_FAILURE"
    $allocatorAllocationCountAfterFailure = Extract-IntValue -Text $out -Name "ALLOCATOR_ALLOCATION_COUNT_AFTER_FAILURE"
    $allocatorBytesInUseAfterFailure = Extract-IntValue -Text $out -Name "ALLOCATOR_BYTES_IN_USE_AFTER_FAILURE"
    $blockedResult = Extract-IntValue -Text $out -Name "BLOCKED_RESULT"
    $commandResultOkCount = Extract-IntValue -Text $out -Name "COMMAND_RESULT_OK_COUNT"
    $commandResultInvalidCount = Extract-IntValue -Text $out -Name "COMMAND_RESULT_INVALID_COUNT"
    $commandResultNotSupportedCount = Extract-IntValue -Text $out -Name "COMMAND_RESULT_NOT_SUPPORTED_COUNT"
    $commandResultOtherErrorCount = Extract-IntValue -Text $out -Name "COMMAND_RESULT_OTHER_ERROR_COUNT"
    $commandResultTotalCount = Extract-IntValue -Text $out -Name "COMMAND_RESULT_TOTAL_COUNT"
    $commandResultLastResult = Extract-IntValue -Text $out -Name "COMMAND_RESULT_LAST_RESULT"
    $commandResultLastOpcode = Extract-IntValue -Text $out -Name "COMMAND_RESULT_LAST_OPCODE"
    $commandResultLastSeq = Extract-IntValue -Text $out -Name "COMMAND_RESULT_LAST_SEQ"
    $syscallEnabled = Extract-IntValue -Text $out -Name "SYSCALL_ENABLED"
    $syscallEntryCount = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY_COUNT"
    $syscallLastId = Extract-IntValue -Text $out -Name "SYSCALL_LAST_ID"
    $syscallDispatchCount = Extract-IntValue -Text $out -Name "SYSCALL_DISPATCH_COUNT"
    $syscallLastInvokeTick = Extract-IntValue -Text $out -Name "SYSCALL_LAST_INVOKE_TICK"
    $syscallLastResult = Extract-IntValue -Text $out -Name "SYSCALL_LAST_RESULT"
    $syscallEntry0Id = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY0_ID"
    $syscallEntry0State = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY0_STATE"
    $syscallEntry0Flags = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY0_FLAGS"
    $syscallEntry0Token = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY0_TOKEN"
    $syscallEntry0InvokeCount = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY0_INVOKE_COUNT"
    $syscallEntry0LastArg = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY0_LAST_ARG"
    $syscallEntry0LastResult = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY0_LAST_RESULT"
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
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ALLOCATOR_STATE_ADDR=0x$allocatorStateAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_COUNTERS_ADDR=0x$commandResultCountersAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_STATE_ADDR=0x$syscallStateAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRIES_ADDR=0x$syscallEntriesAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_HIT_AFTER_FAILURE_PATHS=$hitAfterFailurePaths"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_INVALID_ALIGN_RESULT=$invalidAlignResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_NO_SPACE_RESULT=$noSpaceResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ALLOCATOR_FREE_PAGES_AFTER_FAILURE=$allocatorFreePagesAfterFailure"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ALLOCATOR_ALLOCATION_COUNT_AFTER_FAILURE=$allocatorAllocationCountAfterFailure"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_ALLOCATOR_BYTES_IN_USE_AFTER_FAILURE=$allocatorBytesInUseAfterFailure"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_BLOCKED_RESULT=$blockedResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_OK_COUNT=$commandResultOkCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_INVALID_COUNT=$commandResultInvalidCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_NOT_SUPPORTED_COUNT=$commandResultNotSupportedCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_OTHER_ERROR_COUNT=$commandResultOtherErrorCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_TOTAL_COUNT=$commandResultTotalCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_LAST_RESULT=$commandResultLastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_LAST_OPCODE=$commandResultLastOpcode"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_COMMAND_RESULT_LAST_SEQ=$commandResultLastSeq"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENABLED=$syscallEnabled"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY_COUNT=$syscallEntryCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_LAST_ID=$syscallLastId"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_DISPATCH_COUNT=$syscallDispatchCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_LAST_INVOKE_TICK=$syscallLastInvokeTick"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_LAST_RESULT=$syscallLastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_ID=$syscallEntry0Id"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_STATE=$syscallEntry0State"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_FLAGS=$syscallEntry0Flags"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_TOKEN=$syscallEntry0Token"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_INVOKE_COUNT=$syscallEntry0InvokeCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_LAST_ARG=$syscallEntry0LastArg"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_SYSCALL_ENTRY0_LAST_RESULT=$syscallEntry0LastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and
    $hitAfterFailurePaths -and
    (-not $timedOut) -and
    $ack -eq 11 -and
    $lastOpcode -eq $syscallInvokeOpcode -and
    $lastResult -eq -38 -and
    $ticks -ge 10 -and
    $mailboxOpcode -eq $syscallInvokeOpcode -and
    $mailboxSeq -eq 11 -and
    $invalidAlignResult -eq -22 -and
    $noSpaceResult -eq -28 -and
    $allocatorFreePagesAfterFailure -eq 256 -and
    $allocatorAllocationCountAfterFailure -eq 0 -and
    $allocatorBytesInUseAfterFailure -eq 0 -and
    $blockedResult -eq -17 -and
    $commandResultOkCount -eq 4 -and
    $commandResultInvalidCount -eq 1 -and
    $commandResultNotSupportedCount -eq 1 -and
    $commandResultOtherErrorCount -eq 2 -and
    $commandResultTotalCount -eq 8 -and
    $commandResultLastResult -eq -38 -and
    $commandResultLastOpcode -eq $syscallInvokeOpcode -and
    $commandResultLastSeq -eq 11 -and
    $syscallEnabled -eq 0 -and
    $syscallEntryCount -eq 1 -and
    $syscallLastId -eq 0 -and
    $syscallDispatchCount -eq 0 -and
    $syscallLastInvokeTick -eq 0 -and
    $syscallLastResult -eq 0 -and
    $syscallEntry0Id -eq $syscallId -and
    $syscallEntry0State -eq 1 -and
    $syscallEntry0Flags -eq $blockedFlag -and
    $syscallEntry0Token -eq $handlerToken -and
    $syscallEntry0InvokeCount -eq 0 -and
    $syscallEntry0LastArg -eq 0 -and
    $syscallEntry0LastResult -eq 0
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_FAILURE_PROBE=fail"
if (Test-Path $gdbStdout) { Get-Content -Path $gdbStdout -Tail 120 }
if (Test-Path $gdbStderr) { Get-Content -Path $gdbStderr -Tail 120 }
if (Test-Path $qemuStderr) { Get-Content -Path $qemuStderr -Tail 120 }
exit 1
