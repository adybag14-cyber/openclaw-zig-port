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

$allocatorRecordCapacity = 64
$allocatorRecordStride = 48
$allocatorPageCount = 256
$allocSize = 4096
$allocAlignment = 4096
$freshAllocSize = 8192
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_PROBE=skipped"
    return
}

if ($GdbPort -le 0) { $GdbPort = Resolve-FreeTcpPort }

$optionsPath = Join-Path $releaseDir "qemu-allocator-saturation-reset-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-allocator-saturation-reset-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-allocator-saturation-reset-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-allocator-saturation-reset-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-allocator-saturation-reset-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-allocator-saturation-reset-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-allocator-saturation-reset-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-allocator-saturation-reset-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-allocator-saturation-reset-probe-$runStamp.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
@"
pub const qemu_smoke: bool = false;`r`npub const console_probe_banner: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii
    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-allocator-saturation-reset-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for allocator-saturation-reset probe runtime failed with exit code $LASTEXITCODE" }
    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for allocator-saturation-reset probe PVH shim failed with exit code $LASTEXITCODE" }
    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for allocator-saturation-reset probe PVH artifact failed with exit code $LASTEXITCODE" }
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

Remove-PathWithRetry $gdbStdout
Remove-PathWithRetry $gdbStderr
Remove-PathWithRetry $qemuStdout
Remove-PathWithRetry $qemuStderr
$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $_allocated = 0
set $_pre_reset_allocation_count = 0
set $_pre_reset_free_pages = 0
set $_pre_reset_alloc_ops = 0
set $_pre_reset_bytes_in_use = 0
set $_pre_reset_peak_bytes = 0
set $_pre_reset_last_alloc_ptr = 0
set $_pre_reset_first_record_state = 0
set $_pre_reset_last_record_ptr = 0
set $_pre_reset_last_record_page_start = 0
set $_post_reset_free_pages = 0
set $_post_reset_allocation_count = 0
set $_post_reset_alloc_ops = 0
set $_post_reset_free_ops = 0
set $_post_reset_bytes_in_use = 0
set $_post_reset_peak_bytes = 0
set $_post_reset_first_record_state = 0
set $_post_reset_second_record_state = 0
set $_post_reset_bitmap0 = 0
set $_post_reset_bitmap63 = 0
set $_fresh_ptr = 0
set $_fresh_page_len = 0
set $_fresh_allocation_count = 0
set $_fresh_alloc_ops = 0
set $_fresh_bytes_in_use = 0
set $_fresh_peak_bytes = 0
set $_fresh_last_alloc_ptr = 0
set $_fresh_last_alloc_size = 0
set $_fresh_second_record_state = 0
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
      set $_pre_reset_allocation_count = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__)
      set $_pre_reset_free_pages = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_PAGES_OFFSET__)
      set $_pre_reset_alloc_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__)
      set $_pre_reset_bytes_in_use = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__)
      set $_pre_reset_peak_bytes = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__)
      set $_pre_reset_last_alloc_ptr = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_PTR_OFFSET__)
      set $_pre_reset_first_record_state = *(unsigned char*)(__FIRST_RECORD__+__ALLOC_RECORD_STATE_OFFSET__)
      set $_pre_reset_last_record_ptr = *(unsigned long long*)(__LAST_RECORD__+__ALLOC_RECORD_PTR_OFFSET__)
      set $_pre_reset_last_record_page_start = *(unsigned int*)(__LAST_RECORD__+__ALLOC_RECORD_PAGE_START_OFFSET__)
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
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_RESET_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = (__ALLOCATOR_RECORD_CAPACITY__ + 3)
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == (__ALLOCATOR_RECORD_CAPACITY__ + 3) && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __ALLOCATOR_RESET_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == __RESULT_OK__ && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_PAGES_OFFSET__) == __ALLOCATOR_TOTAL_PAGES__ && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__) == 0 && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_OPS_OFFSET__) == 0 && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__) == 0 && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__) == 0 && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_PTR_OFFSET__) == 0 && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_SIZE_OFFSET__) == 0 && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_FREE_PTR_OFFSET__) == 0 && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_FREE_SIZE_OFFSET__) == 0 && *(unsigned char*)(__FIRST_RECORD__+__ALLOC_RECORD_STATE_OFFSET__) == __ALLOC_STATE_UNUSED__ && *(unsigned char*)(__SECOND_RECORD__+__ALLOC_RECORD_STATE_OFFSET__) == __ALLOC_STATE_UNUSED__ && *(unsigned char*)(0x__ALLOCATOR_BITMAP__) == 0 && *(unsigned char*)(0x__ALLOCATOR_BITMAP__ + 63) == 0
    set $_post_reset_free_pages = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_PAGES_OFFSET__)
    set $_post_reset_allocation_count = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__)
    set $_post_reset_alloc_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__)
    set $_post_reset_free_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_FREE_OPS_OFFSET__)
    set $_post_reset_bytes_in_use = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__)
    set $_post_reset_peak_bytes = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__)
    set $_post_reset_first_record_state = *(unsigned char*)(__FIRST_RECORD__+__ALLOC_RECORD_STATE_OFFSET__)
    set $_post_reset_second_record_state = *(unsigned char*)(__SECOND_RECORD__+__ALLOC_RECORD_STATE_OFFSET__)
    set $_post_reset_bitmap0 = *(unsigned char*)(0x__ALLOCATOR_BITMAP__)
    set $_post_reset_bitmap63 = *(unsigned char*)(0x__ALLOCATOR_BITMAP__ + 63)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_ALLOC_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = (__ALLOCATOR_RECORD_CAPACITY__ + 4)
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __FRESH_ALLOC_SIZE__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __ALLOC_ALIGNMENT__
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == (__ALLOCATOR_RECORD_CAPACITY__ + 4) && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __ALLOCATOR_ALLOC_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == __RESULT_OK__ && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__) == 1 && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__) == __FRESH_ALLOC_SIZE__ && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__) == __FRESH_ALLOC_SIZE__ && *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_SIZE_OFFSET__) == __FRESH_ALLOC_SIZE__ && *(unsigned long long*)(__FIRST_RECORD__+__ALLOC_RECORD_PTR_OFFSET__) == *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_HEAP_BASE_OFFSET__) && *(unsigned long long*)(__FIRST_RECORD__+__ALLOC_RECORD_SIZE_OFFSET__) == __FRESH_ALLOC_SIZE__ && *(unsigned int*)(__FIRST_RECORD__+__ALLOC_RECORD_PAGE_LEN_OFFSET__) == 2 && *(unsigned char*)(__FIRST_RECORD__+__ALLOC_RECORD_STATE_OFFSET__) == __ALLOC_STATE_ACTIVE__ && *(unsigned char*)(__SECOND_RECORD__+__ALLOC_RECORD_STATE_OFFSET__) == __ALLOC_STATE_UNUSED__
    set $_fresh_ptr = *(unsigned long long*)(__FIRST_RECORD__+__ALLOC_RECORD_PTR_OFFSET__)
    set $_fresh_page_len = *(unsigned int*)(__FIRST_RECORD__+__ALLOC_RECORD_PAGE_LEN_OFFSET__)
    set $_fresh_allocation_count = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_COUNT_OFFSET__)
    set $_fresh_alloc_ops = *(unsigned int*)(0x__ALLOCATOR_STATE__+__ALLOC_OPS_OFFSET__)
    set $_fresh_bytes_in_use = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_BYTES_IN_USE_OFFSET__)
    set $_fresh_peak_bytes = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_PEAK_BYTES_OFFSET__)
    set $_fresh_last_alloc_ptr = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_PTR_OFFSET__)
    set $_fresh_last_alloc_size = *(unsigned long long*)(0x__ALLOCATOR_STATE__+__ALLOC_LAST_ALLOC_SIZE_OFFSET__)
    set $_fresh_second_record_state = *(unsigned char*)(__SECOND_RECORD__+__ALLOC_RECORD_STATE_OFFSET__)
    printf "HIT_AFTER_ALLOCATOR_SATURATION_RESET_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "STATUS_MODE=%u\n", *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    printf "PRE_RESET_ALLOCATION_COUNT=%u\n", $_pre_reset_allocation_count
    printf "PRE_RESET_FREE_PAGES=%u\n", $_pre_reset_free_pages
    printf "PRE_RESET_ALLOC_OPS=%u\n", $_pre_reset_alloc_ops
    printf "PRE_RESET_BYTES_IN_USE=%llu\n", $_pre_reset_bytes_in_use
    printf "PRE_RESET_PEAK_BYTES=%llu\n", $_pre_reset_peak_bytes
    printf "PRE_RESET_LAST_ALLOC_PTR=%llu\n", $_pre_reset_last_alloc_ptr
    printf "PRE_RESET_FIRST_RECORD_STATE=%u\n", $_pre_reset_first_record_state
    printf "PRE_RESET_LAST_RECORD_PTR=%llu\n", $_pre_reset_last_record_ptr
    printf "PRE_RESET_LAST_RECORD_PAGE_START=%u\n", $_pre_reset_last_record_page_start
    printf "POST_RESET_FREE_PAGES=%u\n", $_post_reset_free_pages
    printf "POST_RESET_ALLOCATION_COUNT=%u\n", $_post_reset_allocation_count
    printf "POST_RESET_ALLOC_OPS=%u\n", $_post_reset_alloc_ops
    printf "POST_RESET_FREE_OPS=%u\n", $_post_reset_free_ops
    printf "POST_RESET_BYTES_IN_USE=%llu\n", $_post_reset_bytes_in_use
    printf "POST_RESET_PEAK_BYTES=%llu\n", $_post_reset_peak_bytes
    printf "POST_RESET_FIRST_RECORD_STATE=%u\n", $_post_reset_first_record_state
    printf "POST_RESET_SECOND_RECORD_STATE=%u\n", $_post_reset_second_record_state
    printf "POST_RESET_BITMAP0=%u\n", $_post_reset_bitmap0
    printf "POST_RESET_BITMAP63=%u\n", $_post_reset_bitmap63
    printf "FRESH_PTR=%llu\n", $_fresh_ptr
    printf "FRESH_PAGE_LEN=%u\n", $_fresh_page_len
    printf "FRESH_ALLOCATION_COUNT=%u\n", $_fresh_allocation_count
    printf "FRESH_ALLOC_OPS=%u\n", $_fresh_alloc_ops
    printf "FRESH_BYTES_IN_USE=%llu\n", $_fresh_bytes_in_use
    printf "FRESH_PEAK_BYTES=%llu\n", $_fresh_peak_bytes
    printf "FRESH_LAST_ALLOC_PTR=%llu\n", $_fresh_last_alloc_ptr
    printf "FRESH_LAST_ALLOC_SIZE=%llu\n", $_fresh_last_alloc_size
    printf "SECOND_RECORD_STATE=%u\n", $_fresh_second_record_state
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
    Replace('__FIRST_RECORD__', $firstRecordAddressExpr).
    Replace('__SECOND_RECORD__', $secondRecordAddressExpr).
    Replace('__LAST_RECORD__', $lastRecordAddressExpr)
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
        throw "Timed out waiting for GDB allocator-saturation-reset probe"
    }

    $gdbOutput = if (Test-Path $gdbStdout) { Get-Content -Raw $gdbStdout } else { "" }
    $gdbError = if (Test-Path $gdbStderr) { Get-Content -Raw $gdbStderr } else { "" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProcess.ExitCode)) { 0 } else { [int]$gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        throw "GDB allocator-saturation-reset probe failed with exit code $gdbExitCode. stdout: $gdbOutput stderr: $gdbError"
    }

    if ($gdbOutput -notmatch 'HIT_AFTER_ALLOCATOR_SATURATION_RESET_PROBE') { throw "Probe did not reach completion marker. Output:`n$gdbOutput" }

    $ack = Extract-IntValue -Text $gdbOutput -Name 'ACK'
    $lastOpcode = Extract-IntValue -Text $gdbOutput -Name 'LAST_OPCODE'
    $lastResult = Extract-IntValue -Text $gdbOutput -Name 'LAST_RESULT'
    $ticks = Extract-IntValue -Text $gdbOutput -Name 'TICKS'
    $statusMode = Extract-IntValue -Text $gdbOutput -Name 'STATUS_MODE'
    $preResetAllocationCount = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_ALLOCATION_COUNT'
    $preResetFreePages = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_FREE_PAGES'
    $preResetAllocOps = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_ALLOC_OPS'
    $preResetBytesInUse = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_BYTES_IN_USE'
    $preResetPeakBytes = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_PEAK_BYTES'
    $preResetLastAllocPtr = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_LAST_ALLOC_PTR'
    $preResetFirstRecordState = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_FIRST_RECORD_STATE'
    $preResetLastRecordPtr = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_LAST_RECORD_PTR'
    $preResetLastRecordPageStart = Extract-IntValue -Text $gdbOutput -Name 'PRE_RESET_LAST_RECORD_PAGE_START'
    $postResetFreePages = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_FREE_PAGES'
    $postResetAllocationCount = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_ALLOCATION_COUNT'
    $postResetAllocOps = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_ALLOC_OPS'
    $postResetFreeOps = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_FREE_OPS'
    $postResetBytesInUse = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_BYTES_IN_USE'
    $postResetPeakBytes = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_PEAK_BYTES'
    $postResetFirstRecordState = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_FIRST_RECORD_STATE'
    $postResetSecondRecordState = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_SECOND_RECORD_STATE'
    $postResetBitmap0 = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_BITMAP0'
    $postResetBitmap63 = Extract-IntValue -Text $gdbOutput -Name 'POST_RESET_BITMAP63'
    $freshPtr = Extract-IntValue -Text $gdbOutput -Name 'FRESH_PTR'
    $freshPageLen = Extract-IntValue -Text $gdbOutput -Name 'FRESH_PAGE_LEN'
    $freshAllocationCount = Extract-IntValue -Text $gdbOutput -Name 'FRESH_ALLOCATION_COUNT'
    $freshAllocOps = Extract-IntValue -Text $gdbOutput -Name 'FRESH_ALLOC_OPS'
    $freshBytesInUse = Extract-IntValue -Text $gdbOutput -Name 'FRESH_BYTES_IN_USE'
    $freshPeakBytes = Extract-IntValue -Text $gdbOutput -Name 'FRESH_PEAK_BYTES'
    $freshLastAllocPtr = Extract-IntValue -Text $gdbOutput -Name 'FRESH_LAST_ALLOC_PTR'
    $freshLastAllocSize = Extract-IntValue -Text $gdbOutput -Name 'FRESH_LAST_ALLOC_SIZE'
    $secondRecordState = Extract-IntValue -Text $gdbOutput -Name 'SECOND_RECORD_STATE'

    if ($ack -ne 68) { throw "Expected ACK=68, got $ack" }
    if ($lastOpcode -ne $allocatorAllocOpcode) { throw "Expected LAST_OPCODE=$allocatorAllocOpcode, got $lastOpcode" }
    if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
    if ($ticks -lt 68) { throw "Expected TICKS >= 68, got $ticks" }
    if ($statusMode -ne $modeRunning) { throw "Expected STATUS_MODE=$modeRunning, got $statusMode" }
    if ($preResetAllocationCount -ne $allocatorRecordCapacity) { throw "Expected PRE_RESET_ALLOCATION_COUNT=$allocatorRecordCapacity, got $preResetAllocationCount" }
    if ($preResetFreePages -ne ($allocatorPageCount - $allocatorRecordCapacity)) { throw "Expected PRE_RESET_FREE_PAGES=$($allocatorPageCount - $allocatorRecordCapacity), got $preResetFreePages" }
    if ($preResetAllocOps -ne $allocatorRecordCapacity) { throw "Expected PRE_RESET_ALLOC_OPS=$allocatorRecordCapacity, got $preResetAllocOps" }
    if ($preResetBytesInUse -ne ($allocatorRecordCapacity * $allocSize)) { throw "Expected PRE_RESET_BYTES_IN_USE=$($allocatorRecordCapacity * $allocSize), got $preResetBytesInUse" }
    if ($preResetPeakBytes -ne ($allocatorRecordCapacity * $allocSize)) { throw "Expected PRE_RESET_PEAK_BYTES=$($allocatorRecordCapacity * $allocSize), got $preResetPeakBytes" }
    if ($preResetLastAllocPtr -le 0) { throw "Expected PRE_RESET_LAST_ALLOC_PTR > 0, got $preResetLastAllocPtr" }
    if ($preResetFirstRecordState -ne $allocationStateActive) { throw "Expected PRE_RESET_FIRST_RECORD_STATE=$allocationStateActive, got $preResetFirstRecordState" }
    if ($preResetLastRecordPtr -le 0) { throw "Expected PRE_RESET_LAST_RECORD_PTR > 0, got $preResetLastRecordPtr" }
    if ($preResetLastRecordPageStart -ne ($allocatorRecordCapacity - 1)) { throw "Expected PRE_RESET_LAST_RECORD_PAGE_START=$($allocatorRecordCapacity - 1), got $preResetLastRecordPageStart" }
    if ($postResetFreePages -ne $allocatorPageCount -or $postResetAllocationCount -ne 0 -or $postResetAllocOps -ne 0 -or $postResetFreeOps -ne 0 -or $postResetBytesInUse -ne 0 -or $postResetPeakBytes -ne 0) { throw "Allocator reset counters did not collapse to baseline" }
    if ($postResetFirstRecordState -ne $allocationStateUnused -or $postResetSecondRecordState -ne $allocationStateUnused -or $postResetBitmap0 -ne 0 -or $postResetBitmap63 -ne 0) { throw "Allocator reset did not clear records/bitmap" }
    if ($freshPtr -ne 0x00100000 -or $freshPageLen -ne 2 -or $freshAllocationCount -ne 1 -or $freshAllocOps -ne 1 -or $freshBytesInUse -ne $freshAllocSize -or $freshPeakBytes -ne $freshAllocSize -or $freshLastAllocPtr -ne $freshPtr -or $freshLastAllocSize -ne $freshAllocSize -or $secondRecordState -ne $allocationStateUnused) { throw "Fresh allocator restart proof failed" }

    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SATURATION_RESET_PROBE=pass"
    Write-Output $gdbOutput.Trim()
}
finally {
    if ($qemuProcess -and -not $qemuProcess.HasExited) { Stop-Process -Id $qemuProcess.Id -Force -ErrorAction SilentlyContinue; try { $qemuProcess.WaitForExit(2000) | Out-Null } catch {} }
    Remove-PathWithRetry $gdbScript
}

