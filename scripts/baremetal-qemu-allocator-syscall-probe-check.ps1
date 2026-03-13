param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1238
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$allocatorResetOpcode = 31
$allocatorAllocOpcode = 32
$allocatorFreeOpcode = 33
$syscallRegisterOpcode = 34
$syscallUnregisterOpcode = 35
$syscallInvokeOpcode = 36
$syscallResetOpcode = 37
$syscallEnableOpcode = 38
$syscallDisableOpcode = 39
$syscallSetFlagsOpcode = 40
$allocSize = 8192
$allocAlignment = 4096
$syscallId = 7
$handlerToken = 0xAA55
$invokeArg = 0x1234
$blockedFlag = 1
$expectedInvokeResult = ($handlerToken -bxor $invokeArg -bxor $syscallId)
$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34
$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24
$allocatorHeapBaseOffset = 0
$allocatorPageSizeOffset = 16
$allocatorFreePagesOffset = 24
$allocatorAllocationCountOffset = 28
$allocatorAllocOpsOffset = 32
$allocatorFreeOpsOffset = 36
$allocatorBytesInUseOffset = 40
$allocatorPeakBytesInUseOffset = 48
$allocatorLastAllocPtrOffset = 56
$allocatorLastAllocSizeOffset = 64
$allocatorLastFreePtrOffset = 72
$allocatorLastFreeSizeOffset = 80
$allocRecordPtrOffset = 0
$allocRecordPageLenOffset = 20
$allocRecordStateOffset = 24
$syscallStateEnabledOffset = 0
$syscallStateEntryCountOffset = 1
$syscallStateLastIdOffset = 4
$syscallStateDispatchCountOffset = 8
$syscallStateLastInvokeTickOffset = 16
$syscallStateLastResultOffset = 24
$syscallEntryStateOffset = 4
$syscallEntryFlagsOffset = 5
$syscallEntryTokenOffset = 8
$syscallEntryInvokeCountOffset = 16
$syscallEntryLastArgOffset = 24
$syscallEntryLastResultOffset = 32

function Resolve-ZigExecutable {
    $default = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
    if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) {
        if (-not (Test-Path $env:OPENCLAW_ZIG_BIN)) { throw "OPENCLAW_ZIG_BIN is set but not found: $($env:OPENCLAW_ZIG_BIN)" }
        return $env:OPENCLAW_ZIG_BIN
    }
    $cmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }
    if (Test-Path $default) { return $default }
    throw "Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure zig is on PATH."
}

function Resolve-PreferredExecutable {
    param([string[]] $Candidates)
    foreach ($name in $Candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

function Resolve-QemuExecutable { return Resolve-PreferredExecutable @("qemu-system-x86_64", "qemu-system-x86_64.exe", "C:\Program Files\qemu\qemu-system-x86_64.exe") }
function Resolve-GdbExecutable { return Resolve-PreferredExecutable @("gdb", "gdb.exe") }
function Resolve-NmExecutable { return Resolve-PreferredExecutable @("llvm-nm", "llvm-nm.exe", "nm", "nm.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\llvm-nm.exe") }
function Resolve-ClangExecutable { return Resolve-PreferredExecutable @("clang", "clang.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\clang.exe") }
function Resolve-LldExecutable { return Resolve-PreferredExecutable @("lld", "lld.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\lld.exe") }

function Resolve-ZigGlobalCacheDir {
    $candidates = @()
    if ($env:ZIG_GLOBAL_CACHE_DIR) { $candidates += $env:ZIG_GLOBAL_CACHE_DIR }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "zig") }
    if ($env:XDG_CACHE_HOME) { $candidates += (Join-Path $env:XDG_CACHE_HOME "zig") }
    if ($env:HOME) { $candidates += (Join-Path $env:HOME ".cache/zig") }
    foreach ($candidate in $candidates) { if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate } }
    return (Join-Path $repo ".zig-global-cache")
}

function Resolve-CompilerRtArchive {
    $cacheRoot = Resolve-ZigGlobalCacheDir
    $objRoot = Join-Path $cacheRoot "o"
    if (-not (Test-Path $objRoot)) { return $null }
    $candidate = Get-ChildItem -Path $objRoot -Recurse -Filter "libcompiler_rt.a" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Resolve-SymbolAddress {
    param([string[]] $SymbolLines, [string] $Pattern, [string] $SymbolName)
    $line = $SymbolLines | Where-Object { $_ -match $Pattern } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($line)) { throw "Failed to resolve symbol address for $SymbolName" }
    $parts = ($line.Trim() -split '\s+')
    if ($parts.Count -lt 3) { throw "Unexpected symbol line while resolving ${SymbolName}: $line" }
    return $parts[0]
}

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, ([regex]::Escape($Name) + '=(-?\d+)'))
    if (-not $match.Success) { return $null }
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-allocator-syscall-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-allocator-syscall-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-allocator-syscall-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-allocator-syscall-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-allocator-syscall-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-allocator-syscall-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-allocator-syscall-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-allocator-syscall-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-allocator-syscall-probe.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
    @"
pub const qemu_smoke: bool = false;`r`npub const console_probe_banner: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii
    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-allocator-syscall-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for allocator-syscall probe runtime failed with exit code $LASTEXITCODE" }
    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for allocator-syscall probe PVH shim failed with exit code $LASTEXITCODE" }
    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for allocator-syscall probe PVH artifact failed with exit code $LASTEXITCODE" }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) { throw "Failed to resolve symbol table from $artifact using $nm" }
$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
$allocatorStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_state$' -SymbolName "baremetal_main.allocator_state"
$allocatorRecordsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_records$' -SymbolName "baremetal_main.allocator_records"
$allocatorBitmapAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_page_bitmap$' -SymbolName "baremetal_main.allocator_page_bitmap"
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
set `$alloc_ptr = 0
set `$allocOpsBeforeReset = 0
set `$freeOpsBeforeReset = 0
set `$peakBytesBeforeReset = 0
set `$syscallDispatchCountBeforeReset = 0
set `$syscallLastIdBeforeReset = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $allocatorAllocOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $allocSize
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $allocAlignment
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set `$alloc_ptr = *(unsigned long long*)(0x$allocatorStateAddress+$allocatorLastAllocPtrOffset)
    printf "ALLOC_PTR_SNAPSHOT=%llu\n", `$alloc_ptr
    printf "ALLOC_FREE_PAGES_AFTER_ALLOC=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorFreePagesOffset)
    printf "ALLOC_RECORD_PAGE_LEN_SNAPSHOT=%u\n", *(unsigned int*)(0x$allocatorRecordsAddress+$allocRecordPageLenOffset)
    printf "ALLOC_RECORD_STATE_SNAPSHOT=%u\n", *(unsigned char*)(0x$allocatorRecordsAddress+$allocRecordStateOffset)
    printf "ALLOC_BITMAP0_AFTER_ALLOC=%u\n", *(unsigned char*)(0x$allocatorBitmapAddress+0)
    printf "ALLOC_BITMAP1_AFTER_ALLOC=%u\n", *(unsigned char*)(0x$allocatorBitmapAddress+1)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallRegisterOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $handlerToken
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallInvokeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $invokeArg
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    printf "INVOKE_LAST_RESULT_SNAPSHOT=%lld\n", *(long long*)(0x$syscallStateAddress+$syscallStateLastResultOffset)
    printf "INVOKE_DISPATCH_COUNT_SNAPSHOT=%llu\n", *(unsigned long long*)(0x$syscallStateAddress+$syscallStateDispatchCountOffset)
    printf "INVOKE_COUNT_SNAPSHOT=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryInvokeCountOffset)
    printf "INVOKE_LAST_ARG_SNAPSHOT=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryLastArgOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallSetFlagsOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $blockedFlag
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallInvokeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $invokeArg
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7
    printf "BLOCKED_COMMAND_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "BLOCKED_INVOKE_COUNT_SNAPSHOT=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryInvokeCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
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
    printf "DISABLED_COMMAND_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallEnableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallSetFlagsOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallInvokeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $invokeArg
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12
    printf "REENABLED_COMMAND_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "REENABLED_DISPATCH_COUNT_SNAPSHOT=%llu\n", *(unsigned long long*)(0x$syscallStateAddress+$syscallStateDispatchCountOffset)
    printf "REENABLED_INVOKE_COUNT_SNAPSHOT=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryInvokeCountOffset)
    printf "REENABLED_LAST_ARG_SNAPSHOT=%llu\n", *(unsigned long long*)(0x$syscallEntriesAddress+$syscallEntryLastArgOffset)
    printf "REENABLED_ENTRY_FLAGS_SNAPSHOT=%u\n", *(unsigned char*)(0x$syscallEntriesAddress+$syscallEntryFlagsOffset)
    printf "REENABLED_LAST_RESULT_SNAPSHOT=%lld\n", *(long long*)(0x$syscallEntriesAddress+$syscallEntryLastResultOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $allocatorFreeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$alloc_ptr
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $allocSize
    set `$stage = 13
  end
  continue
end
if `$stage == 13
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 13
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallUnregisterOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 14
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 14
  end
  continue
end
if `$stage == 14
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 14
    set `$allocOpsBeforeReset = *(unsigned int*)(0x$allocatorStateAddress+$allocatorAllocOpsOffset)
    set `$freeOpsBeforeReset = *(unsigned int*)(0x$allocatorStateAddress+$allocatorFreeOpsOffset)
    set `$peakBytesBeforeReset = *(unsigned long long*)(0x$allocatorStateAddress+$allocatorPeakBytesInUseOffset)
    set `$syscallDispatchCountBeforeReset = *(unsigned long long*)(0x$syscallStateAddress+$syscallStateDispatchCountOffset)
    set `$syscallLastIdBeforeReset = *(unsigned int*)(0x$syscallStateAddress+$syscallStateLastIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $allocatorResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 15
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 15
  end
  continue
end
if `$stage == 15
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 15
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 16
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 16
  end
  continue
end
if `$stage == 16
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 16
    set `$stage = 17
  end
  continue
end
printf "AFTER_ALLOCATOR_SYSCALL\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
printf "ALLOC_OPS_BEFORE_RESET=%u\n", `$allocOpsBeforeReset
printf "FREE_OPS_BEFORE_RESET=%u\n", `$freeOpsBeforeReset
printf "PEAK_BYTES_BEFORE_RESET=%llu\n", `$peakBytesBeforeReset
printf "SYSCALL_DISPATCH_COUNT_BEFORE_RESET=%llu\n", `$syscallDispatchCountBeforeReset
printf "SYSCALL_LAST_ID_BEFORE_RESET=%u\n", `$syscallLastIdBeforeReset
printf "HEAP_BASE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorHeapBaseOffset)
printf "PAGE_SIZE=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorPageSizeOffset)
printf "FREE_PAGES=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorFreePagesOffset)
printf "ALLOCATION_COUNT=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorAllocationCountOffset)
printf "ALLOC_OPS=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorAllocOpsOffset)
printf "FREE_OPS=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorFreeOpsOffset)
printf "BYTES_IN_USE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorBytesInUseOffset)
printf "PEAK_BYTES_IN_USE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorPeakBytesInUseOffset)
printf "LAST_ALLOC_PTR=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorLastAllocPtrOffset)
printf "LAST_ALLOC_SIZE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorLastAllocSizeOffset)
printf "LAST_FREE_PTR=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorLastFreePtrOffset)
printf "LAST_FREE_SIZE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorLastFreeSizeOffset)
printf "BITMAP0=%u\n", *(unsigned char*)(0x$allocatorBitmapAddress+0)
printf "BITMAP1=%u\n", *(unsigned char*)(0x$allocatorBitmapAddress+1)
printf "ALLOC_RECORD0_STATE=%u\n", *(unsigned char*)(0x$allocatorRecordsAddress+$allocRecordStateOffset)
printf "ALLOC_RECORD0_PTR=%llu\n", *(unsigned long long*)(0x$allocatorRecordsAddress+$allocRecordPtrOffset)
printf "ALLOC_RECORD0_PAGE_LEN=%u\n", *(unsigned int*)(0x$allocatorRecordsAddress+$allocRecordPageLenOffset)
printf "SYSCALL_ENABLED=%u\n", *(unsigned char*)(0x$syscallStateAddress+$syscallStateEnabledOffset)
printf "SYSCALL_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$syscallStateAddress+$syscallStateEntryCountOffset)
printf "SYSCALL_LAST_ID=%u\n", *(unsigned int*)(0x$syscallStateAddress+$syscallStateLastIdOffset)
printf "SYSCALL_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$syscallStateAddress+$syscallStateDispatchCountOffset)
printf "SYSCALL_LAST_INVOKE_TICK=%llu\n", *(unsigned long long*)(0x$syscallStateAddress+$syscallStateLastInvokeTickOffset)
printf "SYSCALL_LAST_RESULT=%lld\n", *(long long*)(0x$syscallStateAddress+$syscallStateLastResultOffset)
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
try { $null = Wait-Process -Id $gdbProc.Id -Timeout $TimeoutSeconds -ErrorAction Stop } catch { $timedOut = $true; try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {} } finally { try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {} }
$hitStart = $false
$hitAfterAllocatorSyscall = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$allocPtrSnapshot = $null
$allocFreePagesAfterAlloc = $null
$allocRecordPageLenSnapshot = $null
$allocRecordStateSnapshot = $null
$allocBitmap0AfterAlloc = $null
$allocBitmap1AfterAlloc = $null
$invokeLastResultSnapshot = $null
$invokeDispatchCountSnapshot = $null
$invokeCountSnapshot = $null
$invokeLastArgSnapshot = $null
$blockedCommandResult = $null
$blockedInvokeCountSnapshot = $null
$disabledCommandResult = $null
$reenabledCommandResult = $null
$reenabledDispatchCountSnapshot = $null
$reenabledInvokeCountSnapshot = $null
$reenabledLastArgSnapshot = $null
$reenabledEntryFlagsSnapshot = $null
$reenabledLastResultSnapshot = $null
$allocOpsBeforeReset = $null
$freeOpsBeforeReset = $null
$peakBytesBeforeReset = $null
$syscallDispatchCountBeforeReset = $null
$syscallLastIdBeforeReset = $null
$heapBase = $null
$pageSize = $null
$freePages = $null
$allocationCount = $null
$allocOps = $null
$freeOps = $null
$bytesInUse = $null
$peakBytesInUse = $null
$lastAllocPtr = $null
$lastAllocSize = $null
$lastFreePtr = $null
$lastFreeSize = $null
$bitmap0 = $null
$bitmap1 = $null
$allocRecord0State = $null
$allocRecord0Ptr = $null
$allocRecord0PageLen = $null
$syscallEnabled = $null
$syscallEntryCount = $null
$syscallLastId = $null
$syscallDispatchCount = $null
$syscallLastInvokeTick = $null
$syscallLastResult = $null
$syscallEntry0State = $null
$syscallEntry0Flags = $null
$syscallEntry0Token = $null
$syscallEntry0InvokeCount = $null
$syscallEntry0LastArg = $null
$syscallEntry0LastResult = $null
if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterAllocatorSyscall = $out -match "AFTER_ALLOCATOR_SYSCALL"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $allocPtrSnapshot = Extract-IntValue -Text $out -Name "ALLOC_PTR_SNAPSHOT"
    $allocFreePagesAfterAlloc = Extract-IntValue -Text $out -Name "ALLOC_FREE_PAGES_AFTER_ALLOC"
    $allocRecordPageLenSnapshot = Extract-IntValue -Text $out -Name "ALLOC_RECORD_PAGE_LEN_SNAPSHOT"
    $allocRecordStateSnapshot = Extract-IntValue -Text $out -Name "ALLOC_RECORD_STATE_SNAPSHOT"
    $allocBitmap0AfterAlloc = Extract-IntValue -Text $out -Name "ALLOC_BITMAP0_AFTER_ALLOC"
    $allocBitmap1AfterAlloc = Extract-IntValue -Text $out -Name "ALLOC_BITMAP1_AFTER_ALLOC"
    $invokeLastResultSnapshot = Extract-IntValue -Text $out -Name "INVOKE_LAST_RESULT_SNAPSHOT"
    $invokeDispatchCountSnapshot = Extract-IntValue -Text $out -Name "INVOKE_DISPATCH_COUNT_SNAPSHOT"
    $invokeCountSnapshot = Extract-IntValue -Text $out -Name "INVOKE_COUNT_SNAPSHOT"
    $invokeLastArgSnapshot = Extract-IntValue -Text $out -Name "INVOKE_LAST_ARG_SNAPSHOT"
    $blockedCommandResult = Extract-IntValue -Text $out -Name "BLOCKED_COMMAND_RESULT"
    $blockedInvokeCountSnapshot = Extract-IntValue -Text $out -Name "BLOCKED_INVOKE_COUNT_SNAPSHOT"
    $disabledCommandResult = Extract-IntValue -Text $out -Name "DISABLED_COMMAND_RESULT"
    $reenabledCommandResult = Extract-IntValue -Text $out -Name "REENABLED_COMMAND_RESULT"
    $reenabledDispatchCountSnapshot = Extract-IntValue -Text $out -Name "REENABLED_DISPATCH_COUNT_SNAPSHOT"
    $reenabledInvokeCountSnapshot = Extract-IntValue -Text $out -Name "REENABLED_INVOKE_COUNT_SNAPSHOT"
    $reenabledLastArgSnapshot = Extract-IntValue -Text $out -Name "REENABLED_LAST_ARG_SNAPSHOT"
    $reenabledEntryFlagsSnapshot = Extract-IntValue -Text $out -Name "REENABLED_ENTRY_FLAGS_SNAPSHOT"
    $reenabledLastResultSnapshot = Extract-IntValue -Text $out -Name "REENABLED_LAST_RESULT_SNAPSHOT"
    $allocOpsBeforeReset = Extract-IntValue -Text $out -Name "ALLOC_OPS_BEFORE_RESET"
    $freeOpsBeforeReset = Extract-IntValue -Text $out -Name "FREE_OPS_BEFORE_RESET"
    $peakBytesBeforeReset = Extract-IntValue -Text $out -Name "PEAK_BYTES_BEFORE_RESET"
    $syscallDispatchCountBeforeReset = Extract-IntValue -Text $out -Name "SYSCALL_DISPATCH_COUNT_BEFORE_RESET"
    $syscallLastIdBeforeReset = Extract-IntValue -Text $out -Name "SYSCALL_LAST_ID_BEFORE_RESET"
    $heapBase = Extract-IntValue -Text $out -Name "HEAP_BASE"
    $pageSize = Extract-IntValue -Text $out -Name "PAGE_SIZE"
    $freePages = Extract-IntValue -Text $out -Name "FREE_PAGES"
    $allocationCount = Extract-IntValue -Text $out -Name "ALLOCATION_COUNT"
    $allocOps = Extract-IntValue -Text $out -Name "ALLOC_OPS"
    $freeOps = Extract-IntValue -Text $out -Name "FREE_OPS"
    $bytesInUse = Extract-IntValue -Text $out -Name "BYTES_IN_USE"
    $peakBytesInUse = Extract-IntValue -Text $out -Name "PEAK_BYTES_IN_USE"
    $lastAllocPtr = Extract-IntValue -Text $out -Name "LAST_ALLOC_PTR"
    $lastAllocSize = Extract-IntValue -Text $out -Name "LAST_ALLOC_SIZE"
    $lastFreePtr = Extract-IntValue -Text $out -Name "LAST_FREE_PTR"
    $lastFreeSize = Extract-IntValue -Text $out -Name "LAST_FREE_SIZE"
    $bitmap0 = Extract-IntValue -Text $out -Name "BITMAP0"
    $bitmap1 = Extract-IntValue -Text $out -Name "BITMAP1"
    $allocRecord0State = Extract-IntValue -Text $out -Name "ALLOC_RECORD0_STATE"
    $allocRecord0Ptr = Extract-IntValue -Text $out -Name "ALLOC_RECORD0_PTR"
    $allocRecord0PageLen = Extract-IntValue -Text $out -Name "ALLOC_RECORD0_PAGE_LEN"
    $syscallEnabled = Extract-IntValue -Text $out -Name "SYSCALL_ENABLED"
    $syscallEntryCount = Extract-IntValue -Text $out -Name "SYSCALL_ENTRY_COUNT"
    $syscallLastId = Extract-IntValue -Text $out -Name "SYSCALL_LAST_ID"
    $syscallDispatchCount = Extract-IntValue -Text $out -Name "SYSCALL_DISPATCH_COUNT"
    $syscallLastInvokeTick = Extract-IntValue -Text $out -Name "SYSCALL_LAST_INVOKE_TICK"
    $syscallLastResult = Extract-IntValue -Text $out -Name "SYSCALL_LAST_RESULT"
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
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOCATOR_STATE_ADDR=0x$allocatorStateAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOCATOR_RECORDS_ADDR=0x$allocatorRecordsAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOCATOR_BITMAP_ADDR=0x$allocatorBitmapAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_STATE_ADDR=0x$syscallStateAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRIES_ADDR=0x$syscallEntriesAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_HIT_AFTER_ALLOCATOR_SYSCALL=$hitAfterAllocatorSyscall"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_PTR_SNAPSHOT=$allocPtrSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_FREE_PAGES_AFTER_ALLOC=$allocFreePagesAfterAlloc"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_RECORD_PAGE_LEN_SNAPSHOT=$allocRecordPageLenSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_RECORD_STATE_SNAPSHOT=$allocRecordStateSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_BITMAP0_AFTER_ALLOC=$allocBitmap0AfterAlloc"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_BITMAP1_AFTER_ALLOC=$allocBitmap1AfterAlloc"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_LAST_RESULT_SNAPSHOT=$invokeLastResultSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_DISPATCH_COUNT_SNAPSHOT=$invokeDispatchCountSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_COUNT_SNAPSHOT=$invokeCountSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_LAST_ARG_SNAPSHOT=$invokeLastArgSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_BLOCKED_COMMAND_RESULT=$blockedCommandResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_BLOCKED_INVOKE_COUNT_SNAPSHOT=$blockedInvokeCountSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_DISABLED_COMMAND_RESULT=$disabledCommandResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_COMMAND_RESULT=$reenabledCommandResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_DISPATCH_COUNT_SNAPSHOT=$reenabledDispatchCountSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_INVOKE_COUNT_SNAPSHOT=$reenabledInvokeCountSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_LAST_ARG_SNAPSHOT=$reenabledLastArgSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_ENTRY_FLAGS_SNAPSHOT=$reenabledEntryFlagsSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_LAST_RESULT_SNAPSHOT=$reenabledLastResultSnapshot"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_OPS_BEFORE_RESET=$allocOpsBeforeReset"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_FREE_OPS_BEFORE_RESET=$freeOpsBeforeReset"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_PEAK_BYTES_BEFORE_RESET=$peakBytesBeforeReset"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_DISPATCH_COUNT_BEFORE_RESET=$syscallDispatchCountBeforeReset"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_LAST_ID_BEFORE_RESET=$syscallLastIdBeforeReset"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_HEAP_BASE=$heapBase"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_PAGE_SIZE=$pageSize"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_FREE_PAGES=$freePages"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOCATION_COUNT=$allocationCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_OPS=$allocOps"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_FREE_OPS=$freeOps"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_BYTES_IN_USE=$bytesInUse"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_PEAK_BYTES_IN_USE=$peakBytesInUse"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_ALLOC_PTR=$lastAllocPtr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_ALLOC_SIZE=$lastAllocSize"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_FREE_PTR=$lastFreePtr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_LAST_FREE_SIZE=$lastFreeSize"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_BITMAP0=$bitmap0"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_BITMAP1=$bitmap1"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_RECORD0_STATE=$allocRecord0State"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_RECORD0_PTR=$allocRecord0Ptr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_ALLOC_RECORD0_PAGE_LEN=$allocRecord0PageLen"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENABLED=$syscallEnabled"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRY_COUNT=$syscallEntryCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_LAST_ID=$syscallLastId"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_DISPATCH_COUNT=$syscallDispatchCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_LAST_INVOKE_TICK=$syscallLastInvokeTick"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_LAST_RESULT=$syscallLastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRY0_STATE=$syscallEntry0State"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRY0_FLAGS=$syscallEntry0Flags"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRY0_TOKEN=$syscallEntry0Token"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRY0_INVOKE_COUNT=$syscallEntry0InvokeCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRY0_LAST_ARG=$syscallEntry0LastArg"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_SYSCALL_ENTRY0_LAST_RESULT=$syscallEntry0LastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and $hitAfterAllocatorSyscall -and (-not $timedOut) -and $ack -eq 16 -and $lastOpcode -eq $syscallResetOpcode -and $lastResult -eq 0 -and $ticks -ge 14 -and $mailboxOpcode -eq $syscallResetOpcode -and $mailboxSeq -eq 16 -and
    $allocPtrSnapshot -ne 0 -and $allocFreePagesAfterAlloc -eq 254 -and $allocRecordPageLenSnapshot -eq 2 -and $allocRecordStateSnapshot -eq 1 -and $allocBitmap0AfterAlloc -eq 1 -and $allocBitmap1AfterAlloc -eq 1 -and
    $invokeLastResultSnapshot -eq $expectedInvokeResult -and $invokeDispatchCountSnapshot -eq 1 -and $invokeCountSnapshot -eq 1 -and $invokeLastArgSnapshot -eq $invokeArg -and $blockedCommandResult -eq -17 -and $blockedInvokeCountSnapshot -eq 1 -and $disabledCommandResult -eq -38 -and
    $reenabledCommandResult -eq 0 -and $reenabledDispatchCountSnapshot -eq 2 -and $reenabledInvokeCountSnapshot -eq 2 -and $reenabledLastArgSnapshot -eq $invokeArg -and $reenabledEntryFlagsSnapshot -eq 0 -and $reenabledLastResultSnapshot -eq $expectedInvokeResult -and
    $allocOpsBeforeReset -eq 1 -and $freeOpsBeforeReset -eq 1 -and $peakBytesBeforeReset -eq $allocSize -and $syscallDispatchCountBeforeReset -eq 2 -and $syscallLastIdBeforeReset -eq $syscallId -and
    $heapBase -eq $allocPtrSnapshot -and $pageSize -eq $allocAlignment -and $freePages -eq 256 -and $allocationCount -eq 0 -and $allocOps -eq 0 -and $freeOps -eq 0 -and $bytesInUse -eq 0 -and $peakBytesInUse -eq 0 -and $lastAllocPtr -eq 0 -and $lastAllocSize -eq 0 -and $lastFreePtr -eq 0 -and $lastFreeSize -eq 0 -and $bitmap0 -eq 0 -and $bitmap1 -eq 0 -and $allocRecord0State -eq 0 -and $allocRecord0Ptr -eq 0 -and $allocRecord0PageLen -eq 0 -and
    $syscallEnabled -eq 1 -and $syscallEntryCount -eq 0 -and $syscallLastId -eq 0 -and $syscallDispatchCount -eq 0 -and $syscallLastInvokeTick -eq 0 -and $syscallLastResult -eq 0 -and $syscallEntry0State -eq 0 -and $syscallEntry0Flags -eq 0 -and $syscallEntry0Token -eq 0 -and $syscallEntry0InvokeCount -eq 0 -and $syscallEntry0LastArg -eq 0 -and $syscallEntry0LastResult -eq 0
)
if ($pass) { Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE=pass"; exit 0 }
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE=fail"
if (Test-Path $gdbStdout) { Get-Content -Path $gdbStdout -Tail 120 }
if (Test-Path $gdbStderr) { Get-Content -Path $gdbStderr -Tail 120 }
if (Test-Path $qemuStderr) { Get-Content -Path $qemuStderr -Tail 120 }
exit 1

