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

$allocSize = 8192
$allocAlignment = 4096
$reallocSize = 4096
$wrongSize = 4096
$resultOk = 0
$resultInvalidArgument = -22
$resultNotFound = -2
$modeRunning = 1

$statusModeOffset = 6
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$allocatorFreePagesOffset = 24
$allocatorAllocationCountOffset = 28
$allocatorLastAllocPtrOffset = 56
$allocatorLastAllocSizeOffset = 64
$allocatorLastFreePtrOffset = 72
$allocatorLastFreeSizeOffset = 80

$allocRecordPageStartOffset = 16
$allocRecordPageLenOffset = 20

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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_FREE_FAILURE_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_FREE_FAILURE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_ALLOCATOR_FREE_FAILURE_PROBE=skipped"
    return
}

if ($GdbPort -le 0) { $GdbPort = Resolve-FreeTcpPort }

$optionsPath = Join-Path $releaseDir "qemu-allocator-free-failure-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-allocator-free-failure-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-allocator-free-failure-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-allocator-free-failure-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-allocator-free-failure-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-allocator-free-failure-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-allocator-free-failure-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-allocator-free-failure-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-allocator-free-failure-probe-$runStamp.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
@"
pub const qemu_smoke: bool = false;`r`npub const console_probe_banner: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii
    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-allocator-free-failure-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for allocator-free-failure probe runtime failed with exit code $LASTEXITCODE" }
    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for allocator-free-failure probe PVH shim failed with exit code $LASTEXITCODE" }
    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for allocator-free-failure probe PVH artifact failed with exit code $LASTEXITCODE" }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) { throw "Failed to resolve symbol table from $artifact using $nm" }

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
$allocatorStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_state$' -SymbolName "baremetal_main.allocator_state"
$allocatorRecord0Address = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_records$' -SymbolName "baremetal_main.allocator_records"
$artifactForGdb = $artifact.Replace('\', '/')

Remove-PathWithRetry $gdbStdout
Remove-PathWithRetry $gdbStderr
Remove-PathWithRetry $qemuStdout
Remove-PathWithRetry $qemuStderr
$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $_alloc_ptr = 0
set $_alloc_free_pages = 0
set $_alloc_count = 0
set $_bad_ptr_result = 0
set $_bad_ptr_free_pages = 0
set $_bad_ptr_count = 0
set $_bad_ptr_last_free_ptr = 0
set $_bad_ptr_last_free_size = 0
set $_bad_size_result = 0
set $_bad_size_free_pages = 0
set $_bad_size_count = 0
set $_bad_size_last_free_ptr = 0
set $_bad_size_last_free_size = 0
set $_good_free_result = 0
set $_good_free_free_pages = 0
set $_good_free_count = 0
set $_good_free_last_free_ptr = 0
set $_good_free_last_free_size = 0
set $_double_free_result = 0
set $_double_free_free_pages = 0
set $_double_free_count = 0
set $_double_free_last_free_ptr = 0
set $_double_free_last_free_size = 0
set $_realloc_ptr = 0
set $_realloc_page_start = 0
set $_realloc_page_len = 0
set $_realloc_free_pages = 0
set $_realloc_count = 0
set $_realloc_last_alloc_ptr = 0
set $_realloc_last_alloc_size = 0
file __ARTIFACT__
handle SIGQUIT nostop noprint pass
target remote :__GDBPORT__
break *0x__START__
commands
  silent
  set {unsigned char}(0x__STATUS__ + __STATUS_MODE_OFFSET__) = __MODE_RUNNING__
  continue
end
break *0x__SPINPAUSE__
commands
  silent
  if $stage == 0
    set $stage = 1
    set {unsigned short}(0x__COMMAND__ + __COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_RESET_OPCODE__
    set {unsigned int}(0x__COMMAND__ + __COMMAND_SEQ_OFFSET__) = 1
    continue
  end
  if $stage == 1 && *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__) == 1
    set $stage = 2
    set {unsigned short}(0x__COMMAND__ + __COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_ALLOC_OPCODE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG0_OFFSET__) = __ALLOC_SIZE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG1_OFFSET__) = __ALLOC_ALIGNMENT__
    set {unsigned int}(0x__COMMAND__ + __COMMAND_SEQ_OFFSET__) = 2
    continue
  end
  if $stage == 2 && *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__) == 2
    set $_alloc_ptr = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_ALLOC_PTR_OFFSET__)
    set $_alloc_free_pages = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_FREE_PAGES_OFFSET__)
    set $_alloc_count = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_ALLOCATION_COUNT_OFFSET__)
    set $stage = 3
    set {unsigned short}(0x__COMMAND__ + __COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_FREE_OPCODE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG0_OFFSET__) = $_alloc_ptr + 4096
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG1_OFFSET__) = 0
    set {unsigned int}(0x__COMMAND__ + __COMMAND_SEQ_OFFSET__) = 3
    continue
  end
  if $stage == 3 && *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__) == 3
    set $_bad_ptr_result = *(short *)(0x__STATUS__ + __STATUS_LAST_COMMAND_RESULT_OFFSET__)
    set $_bad_ptr_free_pages = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_FREE_PAGES_OFFSET__)
    set $_bad_ptr_count = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_ALLOCATION_COUNT_OFFSET__)
    set $_bad_ptr_last_free_ptr = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_PTR_OFFSET__)
    set $_bad_ptr_last_free_size = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_SIZE_OFFSET__)
    set $stage = 4
    set {unsigned short}(0x__COMMAND__ + __COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_FREE_OPCODE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG0_OFFSET__) = $_alloc_ptr
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG1_OFFSET__) = __WRONG_SIZE__
    set {unsigned int}(0x__COMMAND__ + __COMMAND_SEQ_OFFSET__) = 4
    continue
  end
  if $stage == 4 && *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__) == 4
    set $_bad_size_result = *(short *)(0x__STATUS__ + __STATUS_LAST_COMMAND_RESULT_OFFSET__)
    set $_bad_size_free_pages = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_FREE_PAGES_OFFSET__)
    set $_bad_size_count = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_ALLOCATION_COUNT_OFFSET__)
    set $_bad_size_last_free_ptr = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_PTR_OFFSET__)
    set $_bad_size_last_free_size = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_SIZE_OFFSET__)
    set $stage = 5
    set {unsigned short}(0x__COMMAND__ + __COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_FREE_OPCODE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG0_OFFSET__) = $_alloc_ptr
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG1_OFFSET__) = __ALLOC_SIZE__
    set {unsigned int}(0x__COMMAND__ + __COMMAND_SEQ_OFFSET__) = 5
    continue
  end
  if $stage == 5 && *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__) == 5
    set $_good_free_result = *(short *)(0x__STATUS__ + __STATUS_LAST_COMMAND_RESULT_OFFSET__)
    set $_good_free_free_pages = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_FREE_PAGES_OFFSET__)
    set $_good_free_count = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_ALLOCATION_COUNT_OFFSET__)
    set $_good_free_last_free_ptr = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_PTR_OFFSET__)
    set $_good_free_last_free_size = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_SIZE_OFFSET__)
    set $stage = 6
    set {unsigned short}(0x__COMMAND__ + __COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_FREE_OPCODE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG0_OFFSET__) = $_alloc_ptr
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG1_OFFSET__) = 0
    set {unsigned int}(0x__COMMAND__ + __COMMAND_SEQ_OFFSET__) = 6
    continue
  end
  if $stage == 6 && *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__) == 6
    set $_double_free_result = *(short *)(0x__STATUS__ + __STATUS_LAST_COMMAND_RESULT_OFFSET__)
    set $_double_free_free_pages = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_FREE_PAGES_OFFSET__)
    set $_double_free_count = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_ALLOCATION_COUNT_OFFSET__)
    set $_double_free_last_free_ptr = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_PTR_OFFSET__)
    set $_double_free_last_free_size = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_FREE_SIZE_OFFSET__)
    set $stage = 7
    set {unsigned short}(0x__COMMAND__ + __COMMAND_OPCODE_OFFSET__) = __ALLOCATOR_ALLOC_OPCODE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG0_OFFSET__) = __REALLOC_SIZE__
    set {unsigned long long}(0x__COMMAND__ + __COMMAND_ARG1_OFFSET__) = __ALLOC_ALIGNMENT__
    set {unsigned int}(0x__COMMAND__ + __COMMAND_SEQ_OFFSET__) = 7
    continue
  end
  if $stage == 7 && *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__) == 7
    set $_realloc_ptr = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_ALLOC_PTR_OFFSET__)
    set $_realloc_page_start = *(unsigned int *)(0x__ALLOCATOR_RECORD0__ + __ALLOC_RECORD_PAGE_START_OFFSET__)
    set $_realloc_page_len = *(unsigned int *)(0x__ALLOCATOR_RECORD0__ + __ALLOC_RECORD_PAGE_LEN_OFFSET__)
    set $_realloc_free_pages = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_FREE_PAGES_OFFSET__)
    set $_realloc_count = *(unsigned int *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_ALLOCATION_COUNT_OFFSET__)
    set $_realloc_last_alloc_ptr = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_ALLOC_PTR_OFFSET__)
    set $_realloc_last_alloc_size = *(unsigned long long *)(0x__ALLOCATOR_STATE__ + __ALLOCATOR_LAST_ALLOC_SIZE_OFFSET__)
    printf "ACK=%u\n", *(unsigned int *)(0x__STATUS__ + __STATUS_COMMAND_SEQ_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short *)(0x__STATUS__ + __STATUS_LAST_COMMAND_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short *)(0x__STATUS__ + __STATUS_LAST_COMMAND_RESULT_OFFSET__)
    printf "ALLOC_PTR=%llu\n", $_alloc_ptr
    printf "ALLOC_FREE_PAGES=%u\n", $_alloc_free_pages
    printf "ALLOC_COUNT=%u\n", $_alloc_count
    printf "BAD_PTR_RESULT=%d\n", $_bad_ptr_result
    printf "BAD_PTR_FREE_PAGES=%u\n", $_bad_ptr_free_pages
    printf "BAD_PTR_COUNT=%u\n", $_bad_ptr_count
    printf "BAD_PTR_LAST_FREE_PTR=%llu\n", $_bad_ptr_last_free_ptr
    printf "BAD_PTR_LAST_FREE_SIZE=%llu\n", $_bad_ptr_last_free_size
    printf "BAD_SIZE_RESULT=%d\n", $_bad_size_result
    printf "BAD_SIZE_FREE_PAGES=%u\n", $_bad_size_free_pages
    printf "BAD_SIZE_COUNT=%u\n", $_bad_size_count
    printf "BAD_SIZE_LAST_FREE_PTR=%llu\n", $_bad_size_last_free_ptr
    printf "BAD_SIZE_LAST_FREE_SIZE=%llu\n", $_bad_size_last_free_size
    printf "GOOD_FREE_RESULT=%d\n", $_good_free_result
    printf "GOOD_FREE_FREE_PAGES=%u\n", $_good_free_free_pages
    printf "GOOD_FREE_COUNT=%u\n", $_good_free_count
    printf "GOOD_FREE_LAST_FREE_PTR=%llu\n", $_good_free_last_free_ptr
    printf "GOOD_FREE_LAST_FREE_SIZE=%llu\n", $_good_free_last_free_size
    printf "DOUBLE_FREE_RESULT=%d\n", $_double_free_result
    printf "DOUBLE_FREE_FREE_PAGES=%u\n", $_double_free_free_pages
    printf "DOUBLE_FREE_COUNT=%u\n", $_double_free_count
    printf "DOUBLE_FREE_LAST_FREE_PTR=%llu\n", $_double_free_last_free_ptr
    printf "DOUBLE_FREE_LAST_FREE_SIZE=%llu\n", $_double_free_last_free_size
    printf "REALLOC_PTR=%llu\n", $_realloc_ptr
    printf "REALLOC_PAGE_START=%u\n", $_realloc_page_start
    printf "REALLOC_PAGE_LEN=%u\n", $_realloc_page_len
    printf "REALLOC_FREE_PAGES=%u\n", $_realloc_free_pages
    printf "REALLOC_COUNT=%u\n", $_realloc_count
    printf "REALLOC_LAST_ALLOC_PTR=%llu\n", $_realloc_last_alloc_ptr
    printf "REALLOC_LAST_ALLOC_SIZE=%llu\n", $_realloc_last_alloc_size
    quit
  end
  continue
end
continue
'@
$gdbScriptContent = $gdbTemplate.Replace('__ARTIFACT__', $artifactForGdb).
    Replace('__GDBPORT__', "$GdbPort").
    Replace('__START__', $startAddress).
    Replace('__SPINPAUSE__', $spinPauseAddress).
    Replace('__STATUS__', $statusAddress).
    Replace('__COMMAND__', $commandMailboxAddress).
    Replace('__ALLOCATOR_STATE__', $allocatorStateAddress).
    Replace('__ALLOCATOR_RECORD0__', $allocatorRecord0Address).
    Replace('__MODE_RUNNING__', "$modeRunning").
    Replace('__STATUS_MODE_OFFSET__', "$statusModeOffset").
    Replace('__STATUS_COMMAND_SEQ_ACK_OFFSET__', "$statusCommandSeqAckOffset").
    Replace('__STATUS_LAST_COMMAND_OPCODE_OFFSET__', "$statusLastCommandOpcodeOffset").
    Replace('__STATUS_LAST_COMMAND_RESULT_OFFSET__', "$statusLastCommandResultOffset").
    Replace('__COMMAND_OPCODE_OFFSET__', "$commandOpcodeOffset").
    Replace('__COMMAND_SEQ_OFFSET__', "$commandSeqOffset").
    Replace('__COMMAND_ARG0_OFFSET__', "$commandArg0Offset").
    Replace('__COMMAND_ARG1_OFFSET__', "$commandArg1Offset").
    Replace('__ALLOCATOR_FREE_PAGES_OFFSET__', "$allocatorFreePagesOffset").
    Replace('__ALLOCATOR_ALLOCATION_COUNT_OFFSET__', "$allocatorAllocationCountOffset").
    Replace('__ALLOCATOR_LAST_ALLOC_PTR_OFFSET__', "$allocatorLastAllocPtrOffset").
    Replace('__ALLOCATOR_LAST_ALLOC_SIZE_OFFSET__', "$allocatorLastAllocSizeOffset").
    Replace('__ALLOCATOR_LAST_FREE_PTR_OFFSET__', "$allocatorLastFreePtrOffset").
    Replace('__ALLOCATOR_LAST_FREE_SIZE_OFFSET__', "$allocatorLastFreeSizeOffset").
    Replace('__ALLOC_RECORD_PAGE_START_OFFSET__', "$allocRecordPageStartOffset").
    Replace('__ALLOC_RECORD_PAGE_LEN_OFFSET__', "$allocRecordPageLenOffset").
    Replace('__ALLOCATOR_RESET_OPCODE__', "$allocatorResetOpcode").
    Replace('__ALLOCATOR_ALLOC_OPCODE__', "$allocatorAllocOpcode").
    Replace('__ALLOCATOR_FREE_OPCODE__', "$allocatorFreeOpcode").
    Replace('__ALLOC_SIZE__', "$allocSize").
    Replace('__WRONG_SIZE__', "$wrongSize").
    Replace('__REALLOC_SIZE__', "$reallocSize").
    Replace('__ALLOC_ALIGNMENT__', "$allocAlignment")
$gdbScriptContent | Set-Content -Path $gdbScript -Encoding Ascii

$qemuArgs = @(
    "-machine", "q35,accel=tcg",
    "-cpu", "max",
    "-m", "128",
    "-nographic",
    "-serial", "none",
    "-monitor", "none",
    "-display", "none",
    "-kernel", $artifact,
    "-gdb", "tcp::$GdbPort",
    "-S"
)

$qemuProc = $null
try {
    $qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -WorkingDirectory $repo -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -PassThru

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        if ($qemuProc.HasExited) {
            $stderr = if (Test-Path $qemuStderr) { Get-Content $qemuStderr -Raw } else { "" }
            $stdout = if (Test-Path $qemuStdout) { Get-Content $qemuStdout -Raw } else { "" }
            throw "QEMU exited before GDB completed. stdout: $stdout stderr: $stderr"
        }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect('127.0.0.1', $GdbPort, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(100)) {
                $tcp.EndConnect($async)
                $tcp.Close()
                break
            }
            $tcp.Close()
        } catch {
        }
    } while ((Get-Date) -lt $deadline)

    if ((Get-Date) -ge $deadline) {
        throw "Timed out waiting for QEMU GDB server on port $GdbPort"
    }

    $gdbProc = Start-Process -FilePath $gdb -ArgumentList @("--batch", "-x", $gdbScript) -WorkingDirectory $repo -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr -PassThru -WindowStyle Hidden
    if (-not $gdbProc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $gdbProc.Kill() } catch {}
        throw "allocator-free-failure probe gdb timed out after $TimeoutSeconds seconds"
    }
    $gdbExitCode = if ($null -eq $gdbProc.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProc.ExitCode)) { 0 } else { [int]$gdbProc.ExitCode }
    if ($gdbExitCode -ne 0) {
        $stderr = if (Test-Path $gdbStderr) { Get-Content $gdbStderr -Raw } else { "" }
        $stdout = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
        throw "allocator-free-failure probe gdb failed with exit code $gdbExitCode`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
    }
}
finally {
    if ($qemuProc -and -not $qemuProc.HasExited) {
        try { $qemuProc.Kill() } catch {}
        try { $qemuProc.WaitForExit() } catch {}
    }
}

$gdbOutput = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$allocPtr = Extract-IntValue -Text $gdbOutput -Name "ALLOC_PTR"
$allocFreePages = Extract-IntValue -Text $gdbOutput -Name "ALLOC_FREE_PAGES"
$allocCount = Extract-IntValue -Text $gdbOutput -Name "ALLOC_COUNT"
$badPtrResult = Extract-IntValue -Text $gdbOutput -Name "BAD_PTR_RESULT"
$badPtrFreePages = Extract-IntValue -Text $gdbOutput -Name "BAD_PTR_FREE_PAGES"
$badPtrCount = Extract-IntValue -Text $gdbOutput -Name "BAD_PTR_COUNT"
$badPtrLastFreePtr = Extract-IntValue -Text $gdbOutput -Name "BAD_PTR_LAST_FREE_PTR"
$badPtrLastFreeSize = Extract-IntValue -Text $gdbOutput -Name "BAD_PTR_LAST_FREE_SIZE"
$badSizeResult = Extract-IntValue -Text $gdbOutput -Name "BAD_SIZE_RESULT"
$badSizeFreePages = Extract-IntValue -Text $gdbOutput -Name "BAD_SIZE_FREE_PAGES"
$badSizeCount = Extract-IntValue -Text $gdbOutput -Name "BAD_SIZE_COUNT"
$badSizeLastFreePtr = Extract-IntValue -Text $gdbOutput -Name "BAD_SIZE_LAST_FREE_PTR"
$badSizeLastFreeSize = Extract-IntValue -Text $gdbOutput -Name "BAD_SIZE_LAST_FREE_SIZE"
$goodFreeResult = Extract-IntValue -Text $gdbOutput -Name "GOOD_FREE_RESULT"
$goodFreeFreePages = Extract-IntValue -Text $gdbOutput -Name "GOOD_FREE_FREE_PAGES"
$goodFreeCount = Extract-IntValue -Text $gdbOutput -Name "GOOD_FREE_COUNT"
$goodFreeLastFreePtr = Extract-IntValue -Text $gdbOutput -Name "GOOD_FREE_LAST_FREE_PTR"
$goodFreeLastFreeSize = Extract-IntValue -Text $gdbOutput -Name "GOOD_FREE_LAST_FREE_SIZE"
$doubleFreeResult = Extract-IntValue -Text $gdbOutput -Name "DOUBLE_FREE_RESULT"
$doubleFreeFreePages = Extract-IntValue -Text $gdbOutput -Name "DOUBLE_FREE_FREE_PAGES"
$doubleFreeCount = Extract-IntValue -Text $gdbOutput -Name "DOUBLE_FREE_COUNT"
$doubleFreeLastFreePtr = Extract-IntValue -Text $gdbOutput -Name "DOUBLE_FREE_LAST_FREE_PTR"
$doubleFreeLastFreeSize = Extract-IntValue -Text $gdbOutput -Name "DOUBLE_FREE_LAST_FREE_SIZE"
$reallocPtr = Extract-IntValue -Text $gdbOutput -Name "REALLOC_PTR"
$reallocPageStart = Extract-IntValue -Text $gdbOutput -Name "REALLOC_PAGE_START"
$reallocPageLen = Extract-IntValue -Text $gdbOutput -Name "REALLOC_PAGE_LEN"
$reallocFreePages = Extract-IntValue -Text $gdbOutput -Name "REALLOC_FREE_PAGES"
$reallocCount = Extract-IntValue -Text $gdbOutput -Name "REALLOC_COUNT"
$reallocLastAllocPtr = Extract-IntValue -Text $gdbOutput -Name "REALLOC_LAST_ALLOC_PTR"
$reallocLastAllocSize = Extract-IntValue -Text $gdbOutput -Name "REALLOC_LAST_ALLOC_SIZE"
if ($ack -ne 7) { throw "Expected ACK=7, got $ack" }
if ($lastOpcode -ne $allocatorAllocOpcode) { throw "Expected LAST_OPCODE=$allocatorAllocOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($allocPtr -ne 1048576) { throw "Expected ALLOC_PTR=1048576, got $allocPtr" }
if ($allocFreePages -ne 254) { throw "Expected ALLOC_FREE_PAGES=254, got $allocFreePages" }
if ($allocCount -ne 1) { throw "Expected ALLOC_COUNT=1, got $allocCount" }
if ($badPtrResult -ne $resultNotFound) { throw "Expected BAD_PTR_RESULT=$resultNotFound, got $badPtrResult" }
if ($badPtrFreePages -ne 254) { throw "Expected BAD_PTR_FREE_PAGES=254, got $badPtrFreePages" }
if ($badPtrCount -ne 1) { throw "Expected BAD_PTR_COUNT=1, got $badPtrCount" }
if ($badPtrLastFreePtr -ne 0) { throw "Expected BAD_PTR_LAST_FREE_PTR=0, got $badPtrLastFreePtr" }
if ($badPtrLastFreeSize -ne 0) { throw "Expected BAD_PTR_LAST_FREE_SIZE=0, got $badPtrLastFreeSize" }
if ($badSizeResult -ne $resultInvalidArgument) { throw "Expected BAD_SIZE_RESULT=$resultInvalidArgument, got $badSizeResult" }
if ($badSizeFreePages -ne 254) { throw "Expected BAD_SIZE_FREE_PAGES=254, got $badSizeFreePages" }
if ($badSizeCount -ne 1) { throw "Expected BAD_SIZE_COUNT=1, got $badSizeCount" }
if ($badSizeLastFreePtr -ne 0) { throw "Expected BAD_SIZE_LAST_FREE_PTR=0, got $badSizeLastFreePtr" }
if ($badSizeLastFreeSize -ne 0) { throw "Expected BAD_SIZE_LAST_FREE_SIZE=0, got $badSizeLastFreeSize" }
if ($goodFreeResult -ne $resultOk) { throw "Expected GOOD_FREE_RESULT=$resultOk, got $goodFreeResult" }
if ($goodFreeFreePages -ne 256) { throw "Expected GOOD_FREE_FREE_PAGES=256, got $goodFreeFreePages" }
if ($goodFreeCount -ne 0) { throw "Expected GOOD_FREE_COUNT=0, got $goodFreeCount" }
if ($goodFreeLastFreePtr -ne $allocPtr) { throw "Expected GOOD_FREE_LAST_FREE_PTR=$allocPtr, got $goodFreeLastFreePtr" }
if ($goodFreeLastFreeSize -ne $allocSize) { throw "Expected GOOD_FREE_LAST_FREE_SIZE=$allocSize, got $goodFreeLastFreeSize" }
if ($doubleFreeResult -ne $resultNotFound) { throw "Expected DOUBLE_FREE_RESULT=$resultNotFound, got $doubleFreeResult" }
if ($doubleFreeFreePages -ne 256) { throw "Expected DOUBLE_FREE_FREE_PAGES=256, got $doubleFreeFreePages" }
if ($doubleFreeCount -ne 0) { throw "Expected DOUBLE_FREE_COUNT=0, got $doubleFreeCount" }
if ($doubleFreeLastFreePtr -ne $allocPtr) { throw "Expected DOUBLE_FREE_LAST_FREE_PTR=$allocPtr, got $doubleFreeLastFreePtr" }
if ($doubleFreeLastFreeSize -ne $allocSize) { throw "Expected DOUBLE_FREE_LAST_FREE_SIZE=$allocSize, got $doubleFreeLastFreeSize" }
if ($reallocPtr -ne 1048576) { throw "Expected REALLOC_PTR=1048576, got $reallocPtr" }
if ($reallocPageStart -ne 0) { throw "Expected REALLOC_PAGE_START=0, got $reallocPageStart" }
if ($reallocPageLen -ne 1) { throw "Expected REALLOC_PAGE_LEN=1, got $reallocPageLen" }
if ($reallocFreePages -ne 255) { throw "Expected REALLOC_FREE_PAGES=255, got $reallocFreePages" }
if ($reallocCount -ne 1) { throw "Expected REALLOC_COUNT=1, got $reallocCount" }
if ($reallocLastAllocPtr -ne $reallocPtr) { throw "Expected REALLOC_LAST_ALLOC_PTR=$reallocPtr, got $reallocLastAllocPtr" }
if ($reallocLastAllocSize -ne $reallocSize) { throw "Expected REALLOC_LAST_ALLOC_SIZE=$reallocSize, got $reallocLastAllocSize" }

Write-Output "BAREMETAL_QEMU_ALLOCATOR_FREE_FAILURE_PROBE=pass"
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "ALLOC_PTR=$allocPtr"
Write-Output "ALLOC_FREE_PAGES=$allocFreePages"
Write-Output "ALLOC_COUNT=$allocCount"
Write-Output "BAD_PTR_RESULT=$badPtrResult"
Write-Output "BAD_PTR_FREE_PAGES=$badPtrFreePages"
Write-Output "BAD_PTR_COUNT=$badPtrCount"
Write-Output "BAD_PTR_LAST_FREE_PTR=$badPtrLastFreePtr"
Write-Output "BAD_PTR_LAST_FREE_SIZE=$badPtrLastFreeSize"
Write-Output "BAD_SIZE_RESULT=$badSizeResult"
Write-Output "BAD_SIZE_FREE_PAGES=$badSizeFreePages"
Write-Output "BAD_SIZE_COUNT=$badSizeCount"
Write-Output "BAD_SIZE_LAST_FREE_PTR=$badSizeLastFreePtr"
Write-Output "BAD_SIZE_LAST_FREE_SIZE=$badSizeLastFreeSize"
Write-Output "GOOD_FREE_RESULT=$goodFreeResult"
Write-Output "GOOD_FREE_FREE_PAGES=$goodFreeFreePages"
Write-Output "GOOD_FREE_COUNT=$goodFreeCount"
Write-Output "GOOD_FREE_LAST_FREE_PTR=$goodFreeLastFreePtr"
Write-Output "GOOD_FREE_LAST_FREE_SIZE=$goodFreeLastFreeSize"
Write-Output "DOUBLE_FREE_RESULT=$doubleFreeResult"
Write-Output "DOUBLE_FREE_FREE_PAGES=$doubleFreeFreePages"
Write-Output "DOUBLE_FREE_COUNT=$doubleFreeCount"
Write-Output "DOUBLE_FREE_LAST_FREE_PTR=$doubleFreeLastFreePtr"
Write-Output "DOUBLE_FREE_LAST_FREE_SIZE=$doubleFreeLastFreeSize"
Write-Output "REALLOC_PTR=$reallocPtr"
Write-Output "REALLOC_PAGE_START=$reallocPageStart"
Write-Output "REALLOC_PAGE_LEN=$reallocPageLen"
Write-Output "REALLOC_FREE_PAGES=$reallocFreePages"
Write-Output "REALLOC_COUNT=$reallocCount"
Write-Output "REALLOC_LAST_ALLOC_PTR=$reallocLastAllocPtr"
Write-Output "REALLOC_LAST_ALLOC_SIZE=$reallocLastAllocSize"

