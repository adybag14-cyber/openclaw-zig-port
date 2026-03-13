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
$syscallRegisterOpcode = 34
$syscallInvokeOpcode = 36
$syscallResetOpcode = 37

$allocSize = 8192
$allocAlignment = 4096
$syscallId = 12
$handlerToken = 0xCAFE
$invokeArg = 0x55AA
$expectedInvokeResult = ($handlerToken -bxor $invokeArg -bxor $syscallId)
$resultNotFound = -2

$statusModeOffset = 6
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
    $candidate = Get-ChildItem -Path $objRoot -Recurse -Filter "libcompiler_rt.a" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE=skipped"
    return
}

if ($GdbPort -le 0) { $GdbPort = Resolve-FreeTcpPort }

$optionsPath = Join-Path $releaseDir "qemu-allocator-syscall-reset-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-allocator-syscall-reset-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-allocator-syscall-reset-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-allocator-syscall-reset-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-allocator-syscall-reset-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-allocator-syscall-reset-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-allocator-syscall-reset-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-allocator-syscall-reset-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-allocator-syscall-reset-probe-$runStamp.qemu.stderr.log"

if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Allocator-syscall reset artifact not found at $artifact and -SkipBuild was supplied." }

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
@"
pub const qemu_smoke: bool = false;`r`npub const console_probe_banner: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii
    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-allocator-syscall-reset-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for allocator-syscall-reset probe runtime failed with exit code $LASTEXITCODE" }
    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for allocator-syscall-reset probe PVH shim failed with exit code $LASTEXITCODE" }
    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for allocator-syscall-reset probe PVH artifact failed with exit code $LASTEXITCODE" }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) { throw "Failed to resolve symbol table from $artifact using $nm" }

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
$allocatorStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_state$' -SymbolName "baremetal_main.allocator_state"
$allocatorRecordsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_records$' -SymbolName "baremetal_main.allocator_records"
$syscallStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.syscall_state$' -SymbolName "baremetal_main.syscall_state"
$syscallEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.syscall_entries$' -SymbolName "baremetal_main.syscall_entries"
$artifactForGdb = $artifact.Replace('\', '/')

Remove-PathWithRetry $gdbStdout
Remove-PathWithRetry $gdbStderr
Remove-PathWithRetry $qemuStdout
Remove-PathWithRetry $qemuStderr
$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $_dirty_alloc_ptr = 0
set $_dirty_alloc_free_pages = 0
set $_dirty_alloc_count = 0
set $_dirty_alloc_ops = 0
set $_dirty_alloc_bytes = 0
set $_dirty_alloc_peak = 0
set $_dirty_alloc_record0_state = 0
set $_dirty_alloc_record0_page_len = 0
set $_dirty_syscall_entry_count = 0
set $_dirty_syscall_dispatch_count = 0
set $_dirty_syscall_last_id = 0
set $_dirty_syscall_last_invoke_tick = 0
set $_dirty_syscall_last_result = 0
set $_dirty_syscall_entry0_state = 0
set $_dirty_syscall_entry0_token = 0
set $_dirty_syscall_entry0_invoke_count = 0
set $_dirty_syscall_entry0_last_arg = 0
set $_dirty_syscall_entry0_last_result = 0
set $_post_alloc_heap_base = 0
set $_post_alloc_page_size = 0
set $_post_alloc_free_pages = 0
set $_post_alloc_count = 0
set $_post_alloc_ops = 0
set $_post_free_ops = 0
set $_post_alloc_bytes = 0
set $_post_alloc_peak = 0
set $_post_alloc_last_alloc_ptr = 0
set $_post_alloc_last_alloc_size = 0
set $_post_alloc_last_free_ptr = 0
set $_post_alloc_last_free_size = 0
set $_post_alloc_record0_state = 0
set $_post_alloc_record0_ptr = 0
set $_post_alloc_record0_page_len = 0
set $_post_syscall_enabled = 0
set $_post_syscall_entry_count = 0
set $_post_syscall_last_id = 0
set $_post_syscall_dispatch_count = 0
set $_post_syscall_last_invoke_tick = 0
set $_post_syscall_last_result = 0
set $_post_syscall_entry0_state = 0
file __ARTIFACT__
handle SIGQUIT nostop noprint pass
target remote :__GDB_PORT__
break *0x__START_ADDR__
commands
silent
printf "HIT_START\n"
set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __ALLOC_RESET_OPCODE__
set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 1
set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = 0
set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = 0
set $stage = 1
continue
end
break *0x__SPINPAUSE_ADDR__
commands
silent
if $stage == 1
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 1
    set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __SYSCALL_RESET_OPCODE__
    set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 2
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = 0
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = 0
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 2
    set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __ALLOC_OPCODE__
    set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 3
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = __ALLOC_SIZE__
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = __ALLOC_ALIGN__
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 3
    set $_dirty_alloc_ptr = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_LAST_ALLOC_PTR_OFF__)
    set $_dirty_alloc_free_pages = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_FREE_PAGES_OFF__)
    set $_dirty_alloc_count = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_COUNT_OFF__)
    set $_dirty_alloc_ops = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_OPS_OFF__)
    set $_dirty_alloc_bytes = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_BYTES_OFF__)
    set $_dirty_alloc_peak = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_PEAK_OFF__)
    set $_dirty_alloc_record0_state = *(unsigned char*)(0x__ALLOC_RECORDS_ADDR__+__ALLOC_RECORD_STATE_OFF__)
    set $_dirty_alloc_record0_page_len = *(unsigned int*)(0x__ALLOC_RECORDS_ADDR__+__ALLOC_RECORD_PAGE_LEN_OFF__)
    printf "DIRTY_ALLOC_PTR=%llu\n", $_dirty_alloc_ptr
    printf "DIRTY_ALLOC_FREE_PAGES=%u\n", $_dirty_alloc_free_pages
    printf "DIRTY_ALLOC_COUNT=%u\n", $_dirty_alloc_count
    printf "DIRTY_ALLOC_OPS=%u\n", $_dirty_alloc_ops
    printf "DIRTY_ALLOC_BYTES=%llu\n", $_dirty_alloc_bytes
    printf "DIRTY_ALLOC_PEAK=%llu\n", $_dirty_alloc_peak
    printf "DIRTY_ALLOC_RECORD0_STATE=%u\n", $_dirty_alloc_record0_state
    printf "DIRTY_ALLOC_RECORD0_PAGE_LEN=%u\n", $_dirty_alloc_record0_page_len
    set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __SYSCALL_REGISTER_OPCODE__
    set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 4
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = __HANDLER_TOKEN__
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 4
    set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __SYSCALL_INVOKE_OPCODE__
    set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 5
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = __INVOKE_ARG__
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 5
    set $_dirty_syscall_entry_count = *(unsigned char*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_ENTRY_COUNT_OFF__)
    set $_dirty_syscall_dispatch_count = *(unsigned long long*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_DISPATCH_COUNT_OFF__)
    set $_dirty_syscall_last_id = *(unsigned int*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_LAST_ID_OFF__)
    set $_dirty_syscall_last_invoke_tick = *(unsigned long long*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_LAST_INVOKE_TICK_OFF__)
    set $_dirty_syscall_last_result = *(long long*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_LAST_RESULT_OFF__)
    set $_dirty_syscall_entry0_state = *(unsigned char*)(0x__SYSCALL_ENTRIES_ADDR__+__SYSCALL_ENTRY_STATE_OFF__)
    set $_dirty_syscall_entry0_token = *(unsigned long long*)(0x__SYSCALL_ENTRIES_ADDR__+__SYSCALL_ENTRY_TOKEN_OFF__)
    set $_dirty_syscall_entry0_invoke_count = *(unsigned long long*)(0x__SYSCALL_ENTRIES_ADDR__+__SYSCALL_ENTRY_INVOKE_COUNT_OFF__)
    set $_dirty_syscall_entry0_last_arg = *(unsigned long long*)(0x__SYSCALL_ENTRIES_ADDR__+__SYSCALL_ENTRY_LAST_ARG_OFF__)
    set $_dirty_syscall_entry0_last_result = *(long long*)(0x__SYSCALL_ENTRIES_ADDR__+__SYSCALL_ENTRY_LAST_RESULT_OFF__)
    printf "DIRTY_SYSCALL_ENTRY_COUNT=%u\n", $_dirty_syscall_entry_count
    printf "DIRTY_SYSCALL_DISPATCH_COUNT=%llu\n", $_dirty_syscall_dispatch_count
    printf "DIRTY_SYSCALL_LAST_ID=%u\n", $_dirty_syscall_last_id
    printf "DIRTY_SYSCALL_LAST_INVOKE_TICK=%llu\n", $_dirty_syscall_last_invoke_tick
    printf "DIRTY_SYSCALL_LAST_RESULT=%lld\n", $_dirty_syscall_last_result
    printf "DIRTY_SYSCALL_ENTRY0_STATE=%u\n", $_dirty_syscall_entry0_state
    printf "DIRTY_SYSCALL_ENTRY0_TOKEN=%llu\n", $_dirty_syscall_entry0_token
    printf "DIRTY_SYSCALL_ENTRY0_INVOKE_COUNT=%llu\n", $_dirty_syscall_entry0_invoke_count
    printf "DIRTY_SYSCALL_ENTRY0_LAST_ARG=%llu\n", $_dirty_syscall_entry0_last_arg
    printf "DIRTY_SYSCALL_ENTRY0_LAST_RESULT=%lld\n", $_dirty_syscall_entry0_last_result
    set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __ALLOC_RESET_OPCODE__
    set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 6
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = 0
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = 0
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 6
    set $_post_alloc_heap_base = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_HEAP_BASE_OFF__)
    set $_post_alloc_page_size = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_PAGE_SIZE_OFF__)
    set $_post_alloc_free_pages = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_FREE_PAGES_OFF__)
    set $_post_alloc_count = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_COUNT_OFF__)
    set $_post_alloc_ops = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_OPS_OFF__)
    set $_post_free_ops = *(unsigned int*)(0x__ALLOC_STATE_ADDR__+__ALLOC_FREE_OPS_OFF__)
    set $_post_alloc_bytes = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_BYTES_OFF__)
    set $_post_alloc_peak = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_PEAK_OFF__)
    set $_post_alloc_last_alloc_ptr = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_LAST_ALLOC_PTR_OFF__)
    set $_post_alloc_last_alloc_size = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_LAST_ALLOC_SIZE_OFF__)
    set $_post_alloc_last_free_ptr = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_LAST_FREE_PTR_OFF__)
    set $_post_alloc_last_free_size = *(unsigned long long*)(0x__ALLOC_STATE_ADDR__+__ALLOC_LAST_FREE_SIZE_OFF__)
    set $_post_alloc_record0_state = *(unsigned char*)(0x__ALLOC_RECORDS_ADDR__+__ALLOC_RECORD_STATE_OFF__)
    set $_post_alloc_record0_ptr = *(unsigned long long*)(0x__ALLOC_RECORDS_ADDR__+__ALLOC_RECORD_PTR_OFF__)
    set $_post_alloc_record0_page_len = *(unsigned int*)(0x__ALLOC_RECORDS_ADDR__+__ALLOC_RECORD_PAGE_LEN_OFF__)
    printf "POST_ALLOC_HEAP_BASE=%llu\n", $_post_alloc_heap_base
    printf "POST_ALLOC_PAGE_SIZE=%u\n", $_post_alloc_page_size
    printf "POST_ALLOC_FREE_PAGES=%u\n", $_post_alloc_free_pages
    printf "POST_ALLOC_COUNT=%u\n", $_post_alloc_count
    printf "POST_ALLOC_OPS=%u\n", $_post_alloc_ops
    printf "POST_ALLOC_FREE_OPS=%u\n", $_post_free_ops
    printf "POST_ALLOC_BYTES=%llu\n", $_post_alloc_bytes
    printf "POST_ALLOC_PEAK=%llu\n", $_post_alloc_peak
    printf "POST_ALLOC_LAST_ALLOC_PTR=%llu\n", $_post_alloc_last_alloc_ptr
    printf "POST_ALLOC_LAST_ALLOC_SIZE=%llu\n", $_post_alloc_last_alloc_size
    printf "POST_ALLOC_LAST_FREE_PTR=%llu\n", $_post_alloc_last_free_ptr
    printf "POST_ALLOC_LAST_FREE_SIZE=%llu\n", $_post_alloc_last_free_size
    printf "POST_ALLOC_RECORD0_STATE=%u\n", $_post_alloc_record0_state
    printf "POST_ALLOC_RECORD0_PTR=%llu\n", $_post_alloc_record0_ptr
    printf "POST_ALLOC_RECORD0_PAGE_LEN=%u\n", $_post_alloc_record0_page_len
    set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __SYSCALL_RESET_OPCODE__
    set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 7
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = 0
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = 0
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 7
    set $_post_syscall_enabled = *(unsigned char*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_ENABLED_OFF__)
    set $_post_syscall_entry_count = *(unsigned char*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_ENTRY_COUNT_OFF__)
    set $_post_syscall_last_id = *(unsigned int*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_LAST_ID_OFF__)
    set $_post_syscall_dispatch_count = *(unsigned long long*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_DISPATCH_COUNT_OFF__)
    set $_post_syscall_last_invoke_tick = *(unsigned long long*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_LAST_INVOKE_TICK_OFF__)
    set $_post_syscall_last_result = *(long long*)(0x__SYSCALL_STATE_ADDR__+__SYSCALL_LAST_RESULT_OFF__)
    set $_post_syscall_entry0_state = *(unsigned char*)(0x__SYSCALL_ENTRIES_ADDR__+__SYSCALL_ENTRY_STATE_OFF__)
    printf "POST_SYSCALL_ENABLED=%u\n", $_post_syscall_enabled
    printf "POST_SYSCALL_ENTRY_COUNT=%u\n", $_post_syscall_entry_count
    printf "POST_SYSCALL_LAST_ID=%u\n", $_post_syscall_last_id
    printf "POST_SYSCALL_DISPATCH_COUNT=%llu\n", $_post_syscall_dispatch_count
    printf "POST_SYSCALL_LAST_INVOKE_TICK=%llu\n", $_post_syscall_last_invoke_tick
    printf "POST_SYSCALL_LAST_RESULT=%lld\n", $_post_syscall_last_result
    printf "POST_SYSCALL_ENTRY0_STATE=%u\n", $_post_syscall_entry0_state
    set *(unsigned short*)(0x__MAILBOX_ADDR__+__CMD_OPCODE_OFF__) = __SYSCALL_INVOKE_OPCODE__
    set *(unsigned int*)(0x__MAILBOX_ADDR__+__CMD_SEQ_OFF__) = 8
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG0_OFF__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__MAILBOX_ADDR__+__CMD_ARG1_OFF__) = __INVOKE_ARG__
    set $stage = 8
  end
  continue
end
if $stage == 8
  if *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__) == 8
    set $stage = 9
  end
  continue
end
printf "AFTER_ALLOCATOR_SYSCALL_RESET\n"
printf "ACK=%u\n", *(unsigned int*)(0x__STATUS_ADDR__+__STATUS_ACK_OFF__)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS_ADDR__+__STATUS_LAST_OPCODE_OFF__)
printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS_ADDR__+__STATUS_LAST_RESULT_OFF__)
printf "MODE=%u\n", *(unsigned char*)(0x__STATUS_ADDR__+__STATUS_MODE_OFF__)
printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS_ADDR__+__STATUS_TICKS_OFF__)
quit
end
continue
'@
$gdbScriptContent = $gdbTemplate
$replacements = @{
    "__ARTIFACT__" = $artifactForGdb
    "__GDB_PORT__" = [string]$GdbPort
    "__START_ADDR__" = $startAddress
    "__SPINPAUSE_ADDR__" = $spinPauseAddress
    "__STATUS_ADDR__" = $statusAddress
    "__MAILBOX_ADDR__" = $commandMailboxAddress
    "__ALLOC_STATE_ADDR__" = $allocatorStateAddress
    "__ALLOC_RECORDS_ADDR__" = $allocatorRecordsAddress
    "__SYSCALL_STATE_ADDR__" = $syscallStateAddress
    "__SYSCALL_ENTRIES_ADDR__" = $syscallEntriesAddress
    "__ALLOC_RESET_OPCODE__" = [string]$allocatorResetOpcode
    "__ALLOC_OPCODE__" = [string]$allocatorAllocOpcode
    "__SYSCALL_REGISTER_OPCODE__" = [string]$syscallRegisterOpcode
    "__SYSCALL_INVOKE_OPCODE__" = [string]$syscallInvokeOpcode
    "__SYSCALL_RESET_OPCODE__" = [string]$syscallResetOpcode
    "__ALLOC_SIZE__" = [string]$allocSize
    "__ALLOC_ALIGN__" = [string]$allocAlignment
    "__SYSCALL_ID__" = [string]$syscallId
    "__HANDLER_TOKEN__" = [string]$handlerToken
    "__INVOKE_ARG__" = [string]$invokeArg
    "__STATUS_MODE_OFF__" = [string]$statusModeOffset
    "__STATUS_TICKS_OFF__" = [string]$statusTicksOffset
    "__STATUS_ACK_OFF__" = [string]$statusCommandSeqAckOffset
    "__STATUS_LAST_OPCODE_OFF__" = [string]$statusLastCommandOpcodeOffset
    "__STATUS_LAST_RESULT_OFF__" = [string]$statusLastCommandResultOffset
    "__CMD_OPCODE_OFF__" = [string]$commandOpcodeOffset
    "__CMD_SEQ_OFF__" = [string]$commandSeqOffset
    "__CMD_ARG0_OFF__" = [string]$commandArg0Offset
    "__CMD_ARG1_OFF__" = [string]$commandArg1Offset
    "__ALLOC_HEAP_BASE_OFF__" = [string]$allocatorHeapBaseOffset
    "__ALLOC_PAGE_SIZE_OFF__" = [string]$allocatorPageSizeOffset
    "__ALLOC_FREE_PAGES_OFF__" = [string]$allocatorFreePagesOffset
    "__ALLOC_COUNT_OFF__" = [string]$allocatorAllocationCountOffset
    "__ALLOC_OPS_OFF__" = [string]$allocatorAllocOpsOffset
    "__ALLOC_FREE_OPS_OFF__" = [string]$allocatorFreeOpsOffset
    "__ALLOC_BYTES_OFF__" = [string]$allocatorBytesInUseOffset
    "__ALLOC_PEAK_OFF__" = [string]$allocatorPeakBytesInUseOffset
    "__ALLOC_LAST_ALLOC_PTR_OFF__" = [string]$allocatorLastAllocPtrOffset
    "__ALLOC_LAST_ALLOC_SIZE_OFF__" = [string]$allocatorLastAllocSizeOffset
    "__ALLOC_LAST_FREE_PTR_OFF__" = [string]$allocatorLastFreePtrOffset
    "__ALLOC_LAST_FREE_SIZE_OFF__" = [string]$allocatorLastFreeSizeOffset
    "__ALLOC_RECORD_PTR_OFF__" = [string]$allocRecordPtrOffset
    "__ALLOC_RECORD_PAGE_LEN_OFF__" = [string]$allocRecordPageLenOffset
    "__ALLOC_RECORD_STATE_OFF__" = [string]$allocRecordStateOffset
    "__SYSCALL_ENABLED_OFF__" = [string]$syscallStateEnabledOffset
    "__SYSCALL_ENTRY_COUNT_OFF__" = [string]$syscallStateEntryCountOffset
    "__SYSCALL_LAST_ID_OFF__" = [string]$syscallStateLastIdOffset
    "__SYSCALL_DISPATCH_COUNT_OFF__" = [string]$syscallStateDispatchCountOffset
    "__SYSCALL_LAST_INVOKE_TICK_OFF__" = [string]$syscallStateLastInvokeTickOffset
    "__SYSCALL_LAST_RESULT_OFF__" = [string]$syscallStateLastResultOffset
    "__SYSCALL_ENTRY_STATE_OFF__" = [string]$syscallEntryStateOffset
    "__SYSCALL_ENTRY_TOKEN_OFF__" = [string]$syscallEntryTokenOffset
    "__SYSCALL_ENTRY_INVOKE_COUNT_OFF__" = [string]$syscallEntryInvokeCountOffset
    "__SYSCALL_ENTRY_LAST_ARG_OFF__" = [string]$syscallEntryLastArgOffset
    "__SYSCALL_ENTRY_LAST_RESULT_OFF__" = [string]$syscallEntryLastResultOffset
}
foreach ($pair in $replacements.GetEnumerator()) { $gdbScriptContent = $gdbScriptContent.Replace($pair.Key, $pair.Value) }
$gdbScriptContent | Set-Content -Path $gdbScript -Encoding Ascii

$qemuArgs = @("-kernel", $artifact, "-nographic", "-no-reboot", "-no-shutdown", "-serial", "none", "-monitor", "none", "-S", "-gdb", "tcp::$GdbPort")
$qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
Start-Sleep -Milliseconds 700
$gdbArgs = @("-q", "-batch", "-x", $gdbScript)
$gdbProc = Start-Process -FilePath $gdb -ArgumentList $gdbArgs -PassThru -NoNewWindow -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr
$timedOut = $false
try { $null = Wait-Process -Id $gdbProc.Id -Timeout $TimeoutSeconds -ErrorAction Stop }
catch {
    $timedOut = $true
    try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}
finally {
    try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}
$hitStart = $false
$hitAfterReset = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$mode = $null
$ticks = $null
$dirtyAllocPtr = $null
$dirtyAllocFreePages = $null
$dirtyAllocCount = $null
$dirtyAllocOps = $null
$dirtyAllocBytes = $null
$dirtyAllocPeak = $null
$dirtyAllocRecord0State = $null
$dirtyAllocRecord0PageLen = $null
$dirtySyscallEntryCount = $null
$dirtySyscallDispatchCount = $null
$dirtySyscallLastId = $null
$dirtySyscallLastInvokeTick = $null
$dirtySyscallLastResult = $null
$dirtySyscallEntry0State = $null
$dirtySyscallEntry0Token = $null
$dirtySyscallEntry0InvokeCount = $null
$dirtySyscallEntry0LastArg = $null
$dirtySyscallEntry0LastResult = $null
$postAllocHeapBase = $null
$postAllocPageSize = $null
$postAllocFreePages = $null
$postAllocCount = $null
$postAllocOps = $null
$postAllocFreeOps = $null
$postAllocBytes = $null
$postAllocPeak = $null
$postAllocLastAllocPtr = $null
$postAllocLastAllocSize = $null
$postAllocLastFreePtr = $null
$postAllocLastFreeSize = $null
$postAllocRecord0State = $null
$postAllocRecord0Ptr = $null
$postAllocRecord0PageLen = $null
$postSyscallEnabled = $null
$postSyscallEntryCount = $null
$postSyscallLastId = $null
$postSyscallDispatchCount = $null
$postSyscallLastInvokeTick = $null
$postSyscallLastResult = $null
$postSyscallEntry0State = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterReset = $out -match "AFTER_ALLOCATOR_SYSCALL_RESET"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $mode = Extract-IntValue -Text $out -Name "MODE"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $dirtyAllocPtr = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_PTR"
    $dirtyAllocFreePages = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_FREE_PAGES"
    $dirtyAllocCount = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_COUNT"
    $dirtyAllocOps = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_OPS"
    $dirtyAllocBytes = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_BYTES"
    $dirtyAllocPeak = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_PEAK"
    $dirtyAllocRecord0State = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_RECORD0_STATE"
    $dirtyAllocRecord0PageLen = Extract-IntValue -Text $out -Name "DIRTY_ALLOC_RECORD0_PAGE_LEN"
    $dirtySyscallEntryCount = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_ENTRY_COUNT"
    $dirtySyscallDispatchCount = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_DISPATCH_COUNT"
    $dirtySyscallLastId = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_LAST_ID"
    $dirtySyscallLastInvokeTick = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_LAST_INVOKE_TICK"
    $dirtySyscallLastResult = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_LAST_RESULT"
    $dirtySyscallEntry0State = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_ENTRY0_STATE"
    $dirtySyscallEntry0Token = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_ENTRY0_TOKEN"
    $dirtySyscallEntry0InvokeCount = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_ENTRY0_INVOKE_COUNT"
    $dirtySyscallEntry0LastArg = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_ENTRY0_LAST_ARG"
    $dirtySyscallEntry0LastResult = Extract-IntValue -Text $out -Name "DIRTY_SYSCALL_ENTRY0_LAST_RESULT"
    $postAllocHeapBase = Extract-IntValue -Text $out -Name "POST_ALLOC_HEAP_BASE"
    $postAllocPageSize = Extract-IntValue -Text $out -Name "POST_ALLOC_PAGE_SIZE"
    $postAllocFreePages = Extract-IntValue -Text $out -Name "POST_ALLOC_FREE_PAGES"
    $postAllocCount = Extract-IntValue -Text $out -Name "POST_ALLOC_COUNT"
    $postAllocOps = Extract-IntValue -Text $out -Name "POST_ALLOC_OPS"
    $postAllocFreeOps = Extract-IntValue -Text $out -Name "POST_ALLOC_FREE_OPS"
    $postAllocBytes = Extract-IntValue -Text $out -Name "POST_ALLOC_BYTES"
    $postAllocPeak = Extract-IntValue -Text $out -Name "POST_ALLOC_PEAK"
    $postAllocLastAllocPtr = Extract-IntValue -Text $out -Name "POST_ALLOC_LAST_ALLOC_PTR"
    $postAllocLastAllocSize = Extract-IntValue -Text $out -Name "POST_ALLOC_LAST_ALLOC_SIZE"
    $postAllocLastFreePtr = Extract-IntValue -Text $out -Name "POST_ALLOC_LAST_FREE_PTR"
    $postAllocLastFreeSize = Extract-IntValue -Text $out -Name "POST_ALLOC_LAST_FREE_SIZE"
    $postAllocRecord0State = Extract-IntValue -Text $out -Name "POST_ALLOC_RECORD0_STATE"
    $postAllocRecord0Ptr = Extract-IntValue -Text $out -Name "POST_ALLOC_RECORD0_PTR"
    $postAllocRecord0PageLen = Extract-IntValue -Text $out -Name "POST_ALLOC_RECORD0_PAGE_LEN"
    $postSyscallEnabled = Extract-IntValue -Text $out -Name "POST_SYSCALL_ENABLED"
    $postSyscallEntryCount = Extract-IntValue -Text $out -Name "POST_SYSCALL_ENTRY_COUNT"
    $postSyscallLastId = Extract-IntValue -Text $out -Name "POST_SYSCALL_LAST_ID"
    $postSyscallDispatchCount = Extract-IntValue -Text $out -Name "POST_SYSCALL_DISPATCH_COUNT"
    $postSyscallLastInvokeTick = Extract-IntValue -Text $out -Name "POST_SYSCALL_LAST_INVOKE_TICK"
    $postSyscallLastResult = Extract-IntValue -Text $out -Name "POST_SYSCALL_LAST_RESULT"
    $postSyscallEntry0State = Extract-IntValue -Text $out -Name "POST_SYSCALL_ENTRY0_STATE"
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
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_ALLOCATOR_STATE_ADDR=0x$allocatorStateAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_ALLOCATOR_RECORDS_ADDR=0x$allocatorRecordsAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_SYSCALL_STATE_ADDR=0x$syscallStateAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_SYSCALL_ENTRIES_ADDR=0x$syscallEntriesAddress"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_HIT_AFTER_RESET=$hitAfterReset"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_MODE=$mode"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_PTR=$dirtyAllocPtr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_FREE_PAGES=$dirtyAllocFreePages"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_COUNT=$dirtyAllocCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_OPS=$dirtyAllocOps"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_BYTES=$dirtyAllocBytes"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_PEAK=$dirtyAllocPeak"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_RECORD0_STATE=$dirtyAllocRecord0State"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_RECORD0_PAGE_LEN=$dirtyAllocRecord0PageLen"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_ENTRY_COUNT=$dirtySyscallEntryCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_DISPATCH_COUNT=$dirtySyscallDispatchCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_LAST_ID=$dirtySyscallLastId"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_LAST_INVOKE_TICK=$dirtySyscallLastInvokeTick"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_LAST_RESULT=$dirtySyscallLastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_ENTRY0_STATE=$dirtySyscallEntry0State"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_ENTRY0_TOKEN=$dirtySyscallEntry0Token"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_ENTRY0_INVOKE_COUNT=$dirtySyscallEntry0InvokeCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_ENTRY0_LAST_ARG=$dirtySyscallEntry0LastArg"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_SYSCALL_ENTRY0_LAST_RESULT=$dirtySyscallEntry0LastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_HEAP_BASE=$postAllocHeapBase"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_PAGE_SIZE=$postAllocPageSize"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_FREE_PAGES=$postAllocFreePages"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_COUNT=$postAllocCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_OPS=$postAllocOps"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_FREE_OPS=$postAllocFreeOps"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_BYTES=$postAllocBytes"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_PEAK=$postAllocPeak"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_LAST_ALLOC_PTR=$postAllocLastAllocPtr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_LAST_ALLOC_SIZE=$postAllocLastAllocSize"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_LAST_FREE_PTR=$postAllocLastFreePtr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_LAST_FREE_SIZE=$postAllocLastFreeSize"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_RECORD0_STATE=$postAllocRecord0State"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_RECORD0_PTR=$postAllocRecord0Ptr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_ALLOC_RECORD0_PAGE_LEN=$postAllocRecord0PageLen"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_ENABLED=$postSyscallEnabled"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_ENTRY_COUNT=$postSyscallEntryCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_LAST_ID=$postSyscallLastId"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_DISPATCH_COUNT=$postSyscallDispatchCount"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_LAST_INVOKE_TICK=$postSyscallLastInvokeTick"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_LAST_RESULT=$postSyscallLastResult"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_ENTRY0_STATE=$postSyscallEntry0State"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and $hitAfterReset -and (-not $timedOut) -and $ack -eq 8 -and $lastOpcode -eq $syscallInvokeOpcode -and $lastResult -eq $resultNotFound -and $mode -eq 1 -and $ticks -ge 8 -and
    $dirtyAllocPtr -ne 0 -and $dirtyAllocFreePages -eq 254 -and $dirtyAllocCount -eq 1 -and $dirtyAllocOps -eq 1 -and $dirtyAllocBytes -eq $allocSize -and $dirtyAllocPeak -eq $allocSize -and $dirtyAllocRecord0State -eq 1 -and $dirtyAllocRecord0PageLen -eq 2 -and
    $dirtySyscallEntryCount -eq 1 -and $dirtySyscallDispatchCount -eq 1 -and $dirtySyscallLastId -eq $syscallId -and $dirtySyscallLastInvokeTick -gt 0 -and $dirtySyscallLastResult -eq $expectedInvokeResult -and $dirtySyscallEntry0State -eq 1 -and $dirtySyscallEntry0Token -eq $handlerToken -and $dirtySyscallEntry0InvokeCount -eq 1 -and $dirtySyscallEntry0LastArg -eq $invokeArg -and $dirtySyscallEntry0LastResult -eq $expectedInvokeResult -and
    $postAllocHeapBase -eq $dirtyAllocPtr -and $postAllocPageSize -eq $allocAlignment -and $postAllocFreePages -eq 256 -and $postAllocCount -eq 0 -and $postAllocOps -eq 0 -and $postAllocFreeOps -eq 0 -and $postAllocBytes -eq 0 -and $postAllocPeak -eq 0 -and $postAllocLastAllocPtr -eq 0 -and $postAllocLastAllocSize -eq 0 -and $postAllocLastFreePtr -eq 0 -and $postAllocLastFreeSize -eq 0 -and $postAllocRecord0State -eq 0 -and $postAllocRecord0Ptr -eq 0 -and $postAllocRecord0PageLen -eq 0 -and
    $postSyscallEnabled -eq 1 -and $postSyscallEntryCount -eq 0 -and $postSyscallLastId -eq 0 -and $postSyscallDispatchCount -eq 0 -and $postSyscallLastInvokeTick -eq 0 -and $postSyscallLastResult -eq 0 -and $postSyscallEntry0State -eq 0
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE=fail"
if (Test-Path $gdbStdout) { Get-Content -Path $gdbStdout -Tail 120 }
if (Test-Path $gdbStderr) { Get-Content -Path $gdbStderr -Tail 120 }
if (Test-Path $qemuStderr) { Get-Content -Path $qemuStderr -Tail 120 }
exit 1

