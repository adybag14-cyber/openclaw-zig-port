param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$allocatorResetOpcode = 31
$allocatorAllocOpcode = 32
$allocatorFreeOpcode = 33

$allocatorRecordCapacity = 64
$allocatorRecordStride = 48
$allocatorPageCount = 256
$allocSize = 4096
$allocAlignment = 4096
$freshAllocSize = 8192
$reuseSlotIndex = 5
$resultOk = 0
$resultNoSpace = -28
$modeRunning = 1
$allocationStateUnused = 0
$allocationStateActive = 1

$statusModeOffset = 6
$statusTicksOffset = 8
$statusLastHealthCodeOffset = 16
$statusPanicCountOffset = 24
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$allocatorHeapBaseOffset = 0
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
$allocRecordSizeBytesOffset = 8
$allocRecordPageStartOffset = 16
$allocRecordPageLenOffset = 20
$allocRecordStateOffset = 24

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

function Resolve-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
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
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Remove-PathWithRetry {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return }
    for ($attempt = 0; $attempt -lt 5; $attempt += 1) {
        try { Remove-Item -Force -ErrorAction Stop $Path; return }
        catch { if ($attempt -ge 4) { throw }; Start-Sleep -Milliseconds 100 }
    }
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_REUSE_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_REUSE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_REUSE_PROBE=skipped"
    return
}

if ($GdbPort -le 0) { $GdbPort = Resolve-FreeTcpPort }

$optionsPath = Join-Path $releaseDir "qemu-allocator-saturation-reuse-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-allocator-saturation-reuse-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-allocator-saturation-reuse-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-allocator-saturation-reuse-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-allocator-saturation-reuse-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-allocator-saturation-reuse-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-allocator-saturation-reuse-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-allocator-saturation-reuse-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-allocator-saturation-reuse-probe-$runStamp.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
@"
pub const qemu_smoke: bool = false;`r`npub const console_probe_banner: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii
    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-allocator-saturation-reuse-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for allocator-saturation-reuse probe runtime failed with exit code $LASTEXITCODE" }
    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for allocator-saturation-reuse probe PVH shim failed with exit code $LASTEXITCODE" }
    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for allocator-saturation-reuse probe PVH artifact failed with exit code $LASTEXITCODE" }
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
$artifactForGdb = $artifact.Replace('\', '/')
$firstRecordAddressExpr = "(0x$allocatorRecordsAddress)"
$secondRecordAddressExpr = "(0x$allocatorRecordsAddress + $allocatorRecordStride)"
$lastRecordAddressExpr = "(0x$allocatorRecordsAddress + (($allocatorRecordCapacity - 1) * $allocatorRecordStride))"
$reuseRecordAddressExpr = "(0x$allocatorRecordsAddress + ($reuseSlotIndex * $allocatorRecordStride))"
$reuseNeighborRecordAddressExpr = "(0x$allocatorRecordsAddress + (($reuseSlotIndex + 1) * $allocatorRecordStride))"

Remove-PathWithRetry $gdbStdout
Remove-PathWithRetry $gdbStderr
Remove-PathWithRetry $qemuStdout
Remove-PathWithRetry $qemuStderr
$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $_allocated = 0
set $_pre_free_allocation_count = 0
set $_pre_free_free_pages = 0
set $_pre_free_alloc_ops = 0
set $_pre_free_bytes_in_use = 0
set $_pre_free_peak_bytes = 0
set $_pre_free_last_alloc_ptr = 0
set $_pre_free_reuse_record_ptr = 0
set $_pre_free_reuse_record_page_start = 0
set $_pre_free_last_record_ptr = 0
set $_pre_free_last_record_page_start = 0
set $_freed_ptr = 0
set $_post_free_allocation_count = 0
set $_post_free_free_pages = 0
set $_post_free_alloc_ops = 0
set $_post_free_free_ops = 0
set $_post_free_bytes_in_use = 0
set $_post_free_peak_bytes = 0
set $_post_free_last_free_ptr = 0
set $_post_free_last_free_size = 0
set $_post_free_reuse_record_state = 0
set $_post_free_bitmap_reuse_slot = 0
set $_post_reuse_ptr = 0
set $_post_reuse_page_start = 0
set $_post_reuse_page_len = 0
set $_post_reuse_allocation_count = 0
set $_post_reuse_free_pages = 0
set $_post_reuse_alloc_ops = 0
set $_post_reuse_free_ops = 0
set $_post_reuse_bytes_in_use = 0
set $_post_reuse_peak_bytes = 0
set $_post_reuse_last_alloc_ptr = 0
set $_post_reuse_last_alloc_size = 0
set $_post_reuse_neighbor_state = 0
set $_post_reuse_bitmap_reuse_slot = 0
set $_post_reuse_bitmap64 = 0
set $_post_reuse_bitmap65 = 0
file __ARTIFACT__
handle SIGQUIT nostop noprint pass
target remote :__GDBPORT__
break *0x__START__
commands
silent
printf "HIT_START\n"
continue
end
break *0x__SPINPAUSE__
commands
silent
if $stage == 0
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 0
    set *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) = __MODE_RUNNING__
    set *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__) = 0
    set *(unsigned short*)(0x__STATUS__+__STATUS_HEALTH_OFFSET__) = 200
    set *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__) = 0
    set *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) = 0
    set *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) = 0
    set *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) = 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_RESET_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 1
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 1
  end
  continue
end
if $stage == 1
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 1 && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_PAGES_OFFSET__) == __ALLOCATOR_TOTAL_PAGES__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_ALLOC_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 2
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __ALLOC_SIZE__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __ALLOC_ALIGNMENT__
    set $_allocated = 1
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == (1 + $_allocated) && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __ALLOCATOR_ALLOC_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == __RESULT_OK__ && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__) == $_allocated
    if $_allocated < __ALLOCATOR_RECORD_CAPACITY__
      set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_ALLOC_OPCODE__
      set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = (2 + $_allocated)
      set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __ALLOC_SIZE__
      set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __ALLOC_ALIGNMENT__
      set $_allocated = ($_allocated + 1)
    else
      set $_pre_free_allocation_count = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__)
      set $_pre_free_free_pages = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_PAGES_OFFSET__)
      set $_pre_free_alloc_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__)
      set $_pre_free_bytes_in_use = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__)
      set $_pre_free_peak_bytes = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__)
      set $_pre_free_last_alloc_ptr = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_PTR_OFFSET__)
      set $_pre_free_reuse_record_ptr = *(unsigned long long*)(__REUSE_RECORD__+__ALLOC_RECORD_PTR_OFFSET__)
      set $_pre_free_reuse_record_page_start = *(unsigned int*)(__REUSE_RECORD__+__ALLOC_RECORD_PAGE_START_OFFSET__)
      set $_pre_free_last_record_ptr = *(unsigned long long*)(__LAST_RECORD__+__ALLOC_RECORD_PTR_OFFSET__)
      set $_pre_free_last_record_page_start = *(unsigned int*)(__LAST_RECORD__+__ALLOC_RECORD_PAGE_START_OFFSET__)
      set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_ALLOC_OPCODE__
      set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = (__ALLOCATOR_RECORD_CAPACITY__ + 2)
      set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __ALLOC_SIZE__
      set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __ALLOC_ALIGNMENT__
      set $stage = 3
    end
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == (__ALLOCATOR_RECORD_CAPACITY__ + 2) && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __ALLOCATOR_ALLOC_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == __RESULT_NO_SPACE__ && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__) == __ALLOCATOR_RECORD_CAPACITY__
    set $_freed_ptr = $_pre_free_reuse_record_ptr
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_FREE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = (__ALLOCATOR_RECORD_CAPACITY__ + 3)
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $_freed_ptr
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == (__ALLOCATOR_RECORD_CAPACITY__ + 3) && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __ALLOCATOR_FREE_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == __RESULT_OK__
    set $_post_free_allocation_count = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__)
    set $_post_free_free_pages = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_PAGES_OFFSET__)
    set $_post_free_alloc_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__)
    set $_post_free_free_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_OPS_OFFSET__)
    set $_post_free_bytes_in_use = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__)
    set $_post_free_peak_bytes = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__)
    set $_post_free_last_free_ptr = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_FREE_PTR_OFFSET__)
    set $_post_free_last_free_size = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_FREE_SIZE_OFFSET__)
    set $_post_free_reuse_record_state = *(unsigned char*)(__REUSE_RECORD__+__ALLOC_RECORD_STATE_OFFSET__)
    set $_post_free_bitmap_reuse_slot = *(unsigned char*)(0x__ALLOCATOR_BITMAP__ + __REUSE_SLOT_INDEX__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_ALLOC_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = (__ALLOCATOR_RECORD_CAPACITY__ + 4)
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __FRESH_ALLOC_SIZE__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __ALLOC_ALIGNMENT__
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == (__ALLOCATOR_RECORD_CAPACITY__ + 4) && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __ALLOCATOR_ALLOC_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == __RESULT_OK__
    set $_post_reuse_ptr = *(unsigned long long*)(__REUSE_RECORD__+__ALLOC_RECORD_PTR_OFFSET__)
    set $_post_reuse_page_start = *(unsigned int*)(__REUSE_RECORD__+__ALLOC_RECORD_PAGE_START_OFFSET__)
    set $_post_reuse_page_len = *(unsigned int*)(__REUSE_RECORD__+__ALLOC_RECORD_PAGE_LEN_OFFSET__)
    set $_post_reuse_allocation_count = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__)
    set $_post_reuse_free_pages = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_PAGES_OFFSET__)
    set $_post_reuse_alloc_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__)
    set $_post_reuse_free_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_OPS_OFFSET__)
    set $_post_reuse_bytes_in_use = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__)
    set $_post_reuse_peak_bytes = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__)
    set $_post_reuse_last_alloc_ptr = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_PTR_OFFSET__)
    set $_post_reuse_last_alloc_size = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_SIZE_OFFSET__)
    set $_post_reuse_neighbor_state = *(unsigned char*)(__REUSE_NEIGHBOR_RECORD__+__ALLOC_RECORD_STATE_OFFSET__)
    set $_post_reuse_bitmap_reuse_slot = *(unsigned char*)(0x__ALLOCATOR_BITMAP__ + __REUSE_SLOT_INDEX__)
    set $_post_reuse_bitmap64 = *(unsigned char*)(0x__ALLOCATOR_BITMAP__ + __ALLOCATOR_RECORD_CAPACITY__)
    set $_post_reuse_bitmap65 = *(unsigned char*)(0x__ALLOCATOR_BITMAP__ + (__ALLOCATOR_RECORD_CAPACITY__ + 1))
    printf "HIT_AFTER_ALLOCATOR_SATURATION_REUSE_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "STATUS_MODE=%u\n", *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    printf "PRE_FREE_ALLOCATION_COUNT=%u\n", $_pre_free_allocation_count
    printf "PRE_FREE_FREE_PAGES=%u\n", $_pre_free_free_pages
    printf "PRE_FREE_ALLOC_OPS=%u\n", $_pre_free_alloc_ops
    printf "PRE_FREE_BYTES_IN_USE=%llu\n", $_pre_free_bytes_in_use
    printf "PRE_FREE_PEAK_BYTES=%llu\n", $_pre_free_peak_bytes
    printf "PRE_FREE_LAST_ALLOC_PTR=%llu\n", $_pre_free_last_alloc_ptr
    printf "PRE_FREE_REUSE_RECORD_PTR=%llu\n", $_pre_free_reuse_record_ptr
    printf "PRE_FREE_REUSE_RECORD_PAGE_START=%u\n", $_pre_free_reuse_record_page_start
    printf "PRE_FREE_LAST_RECORD_PTR=%llu\n", $_pre_free_last_record_ptr
    printf "PRE_FREE_LAST_RECORD_PAGE_START=%u\n", $_pre_free_last_record_page_start
    printf "POST_FREE_ALLOCATION_COUNT=%u\n", $_post_free_allocation_count
    printf "POST_FREE_FREE_PAGES=%u\n", $_post_free_free_pages
    printf "POST_FREE_ALLOC_OPS=%u\n", $_post_free_alloc_ops
    printf "POST_FREE_FREE_OPS=%u\n", $_post_free_free_ops
    printf "POST_FREE_BYTES_IN_USE=%llu\n", $_post_free_bytes_in_use
    printf "POST_FREE_PEAK_BYTES=%llu\n", $_post_free_peak_bytes
    printf "POST_FREE_LAST_FREE_PTR=%llu\n", $_post_free_last_free_ptr
    printf "POST_FREE_LAST_FREE_SIZE=%llu\n", $_post_free_last_free_size
    printf "POST_FREE_REUSE_RECORD_STATE=%u\n", $_post_free_reuse_record_state
    printf "POST_FREE_BITMAP_REUSE_SLOT=%u\n", $_post_free_bitmap_reuse_slot
    printf "POST_REUSE_PTR=%llu\n", $_post_reuse_ptr
    printf "POST_REUSE_PAGE_START=%u\n", $_post_reuse_page_start
    printf "POST_REUSE_PAGE_LEN=%u\n", $_post_reuse_page_len
    printf "POST_REUSE_ALLOCATION_COUNT=%u\n", $_post_reuse_allocation_count
    printf "POST_REUSE_FREE_PAGES=%u\n", $_post_reuse_free_pages
    printf "POST_REUSE_ALLOC_OPS=%u\n", $_post_reuse_alloc_ops
    printf "POST_REUSE_FREE_OPS=%u\n", $_post_reuse_free_ops
    printf "POST_REUSE_BYTES_IN_USE=%llu\n", $_post_reuse_bytes_in_use
    printf "POST_REUSE_PEAK_BYTES=%llu\n", $_post_reuse_peak_bytes
    printf "POST_REUSE_LAST_ALLOC_PTR=%llu\n", $_post_reuse_last_alloc_ptr
    printf "POST_REUSE_LAST_ALLOC_SIZE=%llu\n", $_post_reuse_last_alloc_size
    printf "POST_REUSE_NEIGHBOR_STATE=%u\n", $_post_reuse_neighbor_state
    printf "POST_REUSE_BITMAP_REUSE_SLOT=%u\n", $_post_reuse_bitmap_reuse_slot
    printf "POST_REUSE_BITMAP64=%u\n", $_post_reuse_bitmap64
    printf "POST_REUSE_BITMAP65=%u\n", $_post_reuse_bitmap65
    detach
    quit
  end
  continue
end
continue
end
continue
'@

$gdbContent = $gdbTemplate.
    Replace('__ARTIFACT__', $artifactForGdb).
    Replace('__GDBPORT__', [string]$GdbPort).
    Replace('__START__', $startAddress).
    Replace('__SPINPAUSE__', $spinPauseAddress).
    Replace('__STATUS__', $statusAddress).
    Replace('__STATUS_MODE_OFFSET__', [string]$statusModeOffset).
    Replace('__STATUS_TICKS_OFFSET__', [string]$statusTicksOffset).
    Replace('__STATUS_HEALTH_OFFSET__', [string]$statusLastHealthCodeOffset).
    Replace('__STATUS_PANIC_OFFSET__', [string]$statusPanicCountOffset).
    Replace('__STATUS_ACK_OFFSET__', [string]$statusCommandSeqAckOffset).
    Replace('__STATUS_LAST_OPCODE_OFFSET__', [string]$statusLastCommandOpcodeOffset).
    Replace('__STATUS_LAST_RESULT_OFFSET__', [string]$statusLastCommandResultOffset).
    Replace('__COMMAND_MAILBOX__', $commandMailboxAddress).
    Replace('__COMMAND_OPCODE_OFFSET__', [string]$commandOpcodeOffset).
    Replace('__COMMAND_SEQ_OFFSET__', [string]$commandSeqOffset).
    Replace('__COMMAND_ARG0_OFFSET__', [string]$commandArg0Offset).
    Replace('__COMMAND_ARG1_OFFSET__', [string]$commandArg1Offset).
    Replace('__ALLOCATOR_STATE__', $allocatorStateAddress).
    Replace('__ALLOCATOR_BITMAP__', $allocatorBitmapAddress).
    Replace('__ALLOC_HEAP_BASE_OFFSET__', [string]$allocatorHeapBaseOffset).
    Replace('__ALLOC_FREE_PAGES_OFFSET__', [string]$allocatorFreePagesOffset).
    Replace('__ALLOC_COUNT_OFFSET__', [string]$allocatorAllocationCountOffset).
    Replace('__ALLOC_OPS_OFFSET__', [string]$allocatorAllocOpsOffset).
    Replace('__ALLOC_FREE_OPS_OFFSET__', [string]$allocatorFreeOpsOffset).
    Replace('__ALLOC_BYTES_IN_USE_OFFSET__', [string]$allocatorBytesInUseOffset).
    Replace('__ALLOC_PEAK_BYTES_OFFSET__', [string]$allocatorPeakBytesInUseOffset).
    Replace('__ALLOC_LAST_ALLOC_PTR_OFFSET__', [string]$allocatorLastAllocPtrOffset).
    Replace('__ALLOC_LAST_ALLOC_SIZE_OFFSET__', [string]$allocatorLastAllocSizeOffset).
    Replace('__ALLOC_LAST_FREE_PTR_OFFSET__', [string]$allocatorLastFreePtrOffset).
    Replace('__ALLOC_LAST_FREE_SIZE_OFFSET__', [string]$allocatorLastFreeSizeOffset).
    Replace('__ALLOC_RECORD_PTR_OFFSET__', [string]$allocRecordPtrOffset).
    Replace('__ALLOC_RECORD_SIZE_OFFSET__', [string]$allocRecordSizeBytesOffset).
    Replace('__ALLOC_RECORD_PAGE_START_OFFSET__', [string]$allocRecordPageStartOffset).
    Replace('__ALLOC_RECORD_PAGE_LEN_OFFSET__', [string]$allocRecordPageLenOffset).
    Replace('__ALLOC_RECORD_STATE_OFFSET__', [string]$allocRecordStateOffset).
    Replace('__ALLOCATOR_RESET_OPCODE__', [string]$allocatorResetOpcode).
    Replace('__ALLOCATOR_ALLOC_OPCODE__', [string]$allocatorAllocOpcode).
    Replace('__ALLOCATOR_FREE_OPCODE__', [string]$allocatorFreeOpcode).
    Replace('__ALLOCATOR_RECORD_CAPACITY__', [string]$allocatorRecordCapacity).
    Replace('__ALLOCATOR_TOTAL_PAGES__', [string]$allocatorPageCount).
    Replace('__ALLOC_SIZE__', [string]$allocSize).
    Replace('__ALLOC_ALIGNMENT__', [string]$allocAlignment).
    Replace('__FRESH_ALLOC_SIZE__', [string]$freshAllocSize).
    Replace('__RESULT_OK__', [string]$resultOk).
    Replace('__RESULT_NO_SPACE__', [string]$resultNoSpace).
    Replace('__MODE_RUNNING__', [string]$modeRunning).
    Replace('__ALLOC_STATE_UNUSED__', [string]$allocationStateUnused).
    Replace('__ALLOC_STATE_ACTIVE__', [string]$allocationStateActive).
    Replace('__REUSE_SLOT_INDEX__', [string]$reuseSlotIndex).
    Replace('__FIRST_RECORD__', $firstRecordAddressExpr).
    Replace('__SECOND_RECORD__', $secondRecordAddressExpr).
    Replace('__LAST_RECORD__', $lastRecordAddressExpr).
    Replace('__REUSE_RECORD__', $reuseRecordAddressExpr).
    Replace('__REUSE_NEIGHBOR_RECORD__', $reuseNeighborRecordAddressExpr)
$gdbContent | Set-Content -Path $gdbScript -Encoding Ascii

$qemuArgs = @('-machine','q35,accel=tcg','-cpu','qemu64','-m','256M','-display','none','-serial','none','-monitor','none','-no-reboot','-kernel',$artifact,'-S','-gdb',"tcp:127.0.0.1:$GdbPort")
$qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -WindowStyle Hidden -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $gdbConnected = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
        if ($qemuProcess.HasExited) { throw "QEMU exited early with code $($qemuProcess.ExitCode)" }
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            try {
                $async = $client.BeginConnect('127.0.0.1', $GdbPort, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(200)) { $client.EndConnect($async); $gdbConnected = $true; break }
            } finally { $client.Dispose() }
        } catch {}
    }

    if (-not $gdbConnected) {
        throw "Timed out waiting for QEMU GDB server on port $GdbPort"
    }

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("--quiet", "--batch", "-x", $gdbScript) -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr -PassThru
    if (-not $gdbProcess.WaitForExit($TimeoutSeconds * 1000)) {
        try { $gdbProcess.Kill() } catch {}
        throw "Timed out waiting for GDB allocator-saturation-reuse probe"
    }

    $gdbOutput = if (Test-Path $gdbStdout) { Get-Content -Raw $gdbStdout } else { "" }
    $gdbError = if (Test-Path $gdbStderr) { Get-Content -Raw $gdbStderr } else { "" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProcess.ExitCode)) { 0 } else { [int]$gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        throw "GDB allocator-saturation-reuse probe failed with exit code $gdbExitCode. stdout: $gdbOutput stderr: $gdbError"
    }

    if ($gdbOutput -notmatch 'HIT_AFTER_ALLOCATOR_SATURATION_REUSE_PROBE') { throw "Probe did not reach completion marker. Output:`n$gdbOutput" }

    $ack = Extract-IntValue -Text $gdbOutput -Name 'ACK'
    $lastOpcode = Extract-IntValue -Text $gdbOutput -Name 'LAST_OPCODE'
    $lastResult = Extract-IntValue -Text $gdbOutput -Name 'LAST_RESULT'
    $ticks = Extract-IntValue -Text $gdbOutput -Name 'TICKS'
    $statusMode = Extract-IntValue -Text $gdbOutput -Name 'STATUS_MODE'
    $preFreeAllocationCount = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_ALLOCATION_COUNT'
    $preFreeFreePages = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_FREE_PAGES'
    $preFreeAllocOps = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_ALLOC_OPS'
    $preFreeBytesInUse = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_BYTES_IN_USE'
    $preFreePeakBytes = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_PEAK_BYTES'
    $preFreeLastAllocPtr = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_LAST_ALLOC_PTR'
    $preFreeReuseRecordPtr = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_REUSE_RECORD_PTR'
    $preFreeReuseRecordPageStart = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_REUSE_RECORD_PAGE_START'
    $preFreeLastRecordPtr = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_LAST_RECORD_PTR'
    $preFreeLastRecordPageStart = Extract-IntValue -Text $gdbOutput -Name 'PRE_FREE_LAST_RECORD_PAGE_START'
    $postFreeAllocationCount = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_ALLOCATION_COUNT'
    $postFreeFreePages = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_FREE_PAGES'
    $postFreeAllocOps = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_ALLOC_OPS'
    $postFreeFreeOps = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_FREE_OPS'
    $postFreeBytesInUse = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_BYTES_IN_USE'
    $postFreePeakBytes = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_PEAK_BYTES'
    $postFreeLastFreePtr = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_LAST_FREE_PTR'
    $postFreeLastFreeSize = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_LAST_FREE_SIZE'
    $postFreeReuseRecordState = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_REUSE_RECORD_STATE'
    $postFreeBitmapReuseSlot = Extract-IntValue -Text $gdbOutput -Name 'POST_FREE_BITMAP_REUSE_SLOT'
    $postReusePtr = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_PTR'
    $postReusePageStart = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_PAGE_START'
    $postReusePageLen = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_PAGE_LEN'
    $postReuseAllocationCount = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_ALLOCATION_COUNT'
    $postReuseFreePages = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_FREE_PAGES'
    $postReuseAllocOps = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_ALLOC_OPS'
    $postReuseFreeOps = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_FREE_OPS'
    $postReuseBytesInUse = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_BYTES_IN_USE'
    $postReusePeakBytes = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_PEAK_BYTES'
    $postReuseLastAllocPtr = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_LAST_ALLOC_PTR'
    $postReuseLastAllocSize = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_LAST_ALLOC_SIZE'
    $postReuseNeighborState = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_NEIGHBOR_STATE'
    $postReuseBitmapReuseSlot = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_BITMAP_REUSE_SLOT'
    $postReuseBitmap64 = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_BITMAP64'
    $postReuseBitmap65 = Extract-IntValue -Text $gdbOutput -Name 'POST_REUSE_BITMAP65'

    $expectedAck = $allocatorRecordCapacity + 4
    $expectedHeapBase = 0x00100000
    $expectedPreFreeFreePages = $allocatorPageCount - $allocatorRecordCapacity
    $expectedPostFreeFreePages = $allocatorPageCount - ($allocatorRecordCapacity - 1)
    $expectedPostReuseFreePages = $allocatorPageCount - ($allocatorRecordCapacity + 1)
    $expectedPreFreeBytesInUse = $allocatorRecordCapacity * $allocSize
    $expectedPostFreeBytesInUse = ($allocatorRecordCapacity - 1) * $allocSize
    $expectedPostReuseBytesInUse = ($allocatorRecordCapacity * $allocSize) - $allocSize + $freshAllocSize
    $expectedReusePtr = $expectedHeapBase + ($reuseSlotIndex * $allocSize)
    $expectedLastRecordPtr = $expectedHeapBase + (($allocatorRecordCapacity - 1) * $allocSize)
    $expectedPostReusePtr = $expectedHeapBase + ($allocatorRecordCapacity * $allocSize)

    if ($ack -ne $expectedAck) { throw "Expected ACK=$expectedAck, got $ack" }
    if ($lastOpcode -ne $allocatorAllocOpcode) { throw "Expected LAST_OPCODE=$allocatorAllocOpcode, got $lastOpcode" }
    if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
    if ($ticks -lt $expectedAck) { throw "Expected TICKS >= $expectedAck, got $ticks" }
    if ($statusMode -ne $modeRunning) { throw "Expected STATUS_MODE=$modeRunning, got $statusMode" }

    if ($preFreeAllocationCount -ne $allocatorRecordCapacity) { throw "Expected PRE_FREE_ALLOCATION_COUNT=$allocatorRecordCapacity, got $preFreeAllocationCount" }
    if ($preFreeFreePages -ne $expectedPreFreeFreePages) { throw "Expected PRE_FREE_FREE_PAGES=$expectedPreFreeFreePages, got $preFreeFreePages" }
    if ($preFreeAllocOps -ne $allocatorRecordCapacity) { throw "Expected PRE_FREE_ALLOC_OPS=$allocatorRecordCapacity, got $preFreeAllocOps" }
    if ($preFreeBytesInUse -ne $expectedPreFreeBytesInUse) { throw "Expected PRE_FREE_BYTES_IN_USE=$expectedPreFreeBytesInUse, got $preFreeBytesInUse" }
    if ($preFreePeakBytes -ne $expectedPreFreeBytesInUse) { throw "Expected PRE_FREE_PEAK_BYTES=$expectedPreFreeBytesInUse, got $preFreePeakBytes" }
    if ($preFreeLastAllocPtr -ne $expectedLastRecordPtr) { throw "Expected PRE_FREE_LAST_ALLOC_PTR=$expectedLastRecordPtr, got $preFreeLastAllocPtr" }
    if ($preFreeReuseRecordPtr -ne $expectedReusePtr) { throw "Expected PRE_FREE_REUSE_RECORD_PTR=$expectedReusePtr, got $preFreeReuseRecordPtr" }
    if ($preFreeReuseRecordPageStart -ne $reuseSlotIndex) { throw "Expected PRE_FREE_REUSE_RECORD_PAGE_START=$reuseSlotIndex, got $preFreeReuseRecordPageStart" }
    if ($preFreeLastRecordPtr -ne $expectedLastRecordPtr) { throw "Expected PRE_FREE_LAST_RECORD_PTR=$expectedLastRecordPtr, got $preFreeLastRecordPtr" }
    if ($preFreeLastRecordPageStart -ne ($allocatorRecordCapacity - 1)) { throw "Expected PRE_FREE_LAST_RECORD_PAGE_START=$($allocatorRecordCapacity - 1), got $preFreeLastRecordPageStart" }

    if ($postFreeAllocationCount -ne ($allocatorRecordCapacity - 1)) { throw "Expected POST_FREE_ALLOCATION_COUNT=$($allocatorRecordCapacity - 1), got $postFreeAllocationCount" }
    if ($postFreeFreePages -ne $expectedPostFreeFreePages) { throw "Expected POST_FREE_FREE_PAGES=$expectedPostFreeFreePages, got $postFreeFreePages" }
    if ($postFreeAllocOps -ne $allocatorRecordCapacity) { throw "Expected POST_FREE_ALLOC_OPS=$allocatorRecordCapacity, got $postFreeAllocOps" }
    if ($postFreeFreeOps -ne 1) { throw "Expected POST_FREE_FREE_OPS=1, got $postFreeFreeOps" }
    if ($postFreeBytesInUse -ne $expectedPostFreeBytesInUse) { throw "Expected POST_FREE_BYTES_IN_USE=$expectedPostFreeBytesInUse, got $postFreeBytesInUse" }
    if ($postFreePeakBytes -ne $expectedPreFreeBytesInUse) { throw "Expected POST_FREE_PEAK_BYTES=$expectedPreFreeBytesInUse, got $postFreePeakBytes" }
    if ($postFreeLastFreePtr -ne $preFreeReuseRecordPtr) { throw "Expected POST_FREE_LAST_FREE_PTR=$preFreeReuseRecordPtr, got $postFreeLastFreePtr" }
    if ($postFreeLastFreeSize -ne $allocSize) { throw "Expected POST_FREE_LAST_FREE_SIZE=$allocSize, got $postFreeLastFreeSize" }
    if ($postFreeReuseRecordState -ne $allocationStateUnused) { throw "Expected POST_FREE_REUSE_RECORD_STATE=$allocationStateUnused, got $postFreeReuseRecordState" }
    if ($postFreeBitmapReuseSlot -ne 0) { throw "Expected POST_FREE_BITMAP_REUSE_SLOT=0, got $postFreeBitmapReuseSlot" }

    if ($postReusePtr -ne $expectedPostReusePtr) { throw "Expected POST_REUSE_PTR=$expectedPostReusePtr, got $postReusePtr" }
    if ($postReusePageStart -ne $allocatorRecordCapacity) { throw "Expected POST_REUSE_PAGE_START=$allocatorRecordCapacity, got $postReusePageStart" }
    if ($postReusePageLen -ne 2) { throw "Expected POST_REUSE_PAGE_LEN=2, got $postReusePageLen" }
    if ($postReuseAllocationCount -ne $allocatorRecordCapacity) { throw "Expected POST_REUSE_ALLOCATION_COUNT=$allocatorRecordCapacity, got $postReuseAllocationCount" }
    if ($postReuseFreePages -ne $expectedPostReuseFreePages) { throw "Expected POST_REUSE_FREE_PAGES=$expectedPostReuseFreePages, got $postReuseFreePages" }
    if ($postReuseAllocOps -ne ($allocatorRecordCapacity + 1)) { throw "Expected POST_REUSE_ALLOC_OPS=$($allocatorRecordCapacity + 1), got $postReuseAllocOps" }
    if ($postReuseFreeOps -ne 1) { throw "Expected POST_REUSE_FREE_OPS=1, got $postReuseFreeOps" }
    if ($postReuseBytesInUse -ne $expectedPostReuseBytesInUse) { throw "Expected POST_REUSE_BYTES_IN_USE=$expectedPostReuseBytesInUse, got $postReuseBytesInUse" }
    if ($postReusePeakBytes -ne $expectedPostReuseBytesInUse) { throw "Expected POST_REUSE_PEAK_BYTES=$expectedPostReuseBytesInUse, got $postReusePeakBytes" }
    if ($postReuseLastAllocPtr -ne $expectedPostReusePtr) { throw "Expected POST_REUSE_LAST_ALLOC_PTR=$expectedPostReusePtr, got $postReuseLastAllocPtr" }
    if ($postReuseLastAllocSize -ne $freshAllocSize) { throw "Expected POST_REUSE_LAST_ALLOC_SIZE=$freshAllocSize, got $postReuseLastAllocSize" }
    if ($postReuseNeighborState -ne $allocationStateActive) { throw "Expected POST_REUSE_NEIGHBOR_STATE=$allocationStateActive, got $postReuseNeighborState" }
    if ($postReuseBitmapReuseSlot -ne 0) { throw "Expected POST_REUSE_BITMAP_REUSE_SLOT=0, got $postReuseBitmapReuseSlot" }
    if ($postReuseBitmap64 -ne 1 -or $postReuseBitmap65 -ne 1) { throw "Expected POST_REUSE_BITMAP64/65=1/1, got $postReuseBitmap64/$postReuseBitmap65" }

    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_REUSE_PROBE=pass"
    Write-Output $gdbOutput.Trim()
}
finally {
    if ($qemuProcess -and -not $qemuProcess.HasExited) { Stop-Process -Id $qemuProcess.Id -Force -ErrorAction SilentlyContinue; try { $qemuProcess.WaitForExit(2000) | Out-Null } catch {} }
    Remove-PathWithRetry $gdbScript
}










