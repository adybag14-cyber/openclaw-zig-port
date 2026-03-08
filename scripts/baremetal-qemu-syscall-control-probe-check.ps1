param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1287
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$syscallResetOpcode = 37
$syscallRegisterOpcode = 34
$syscallUnregisterOpcode = 35
$syscallInvokeOpcode = 36
$syscallEnableOpcode = 38
$syscallDisableOpcode = 39
$syscallSetFlagsOpcode = 40

$syscallId = 11
$initialToken = 0xBEEF
$updatedToken = 0xCAFE
$invokeArg = 0x1234
$blockedFlag = 1
$expectedInvokeResult = ($updatedToken -bxor $invokeArg -bxor $syscallId)

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
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }
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
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Remove-PathWithRetry {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return }
    for ($attempt = 0; $attempt -lt 5; $attempt += 1) {
        try {
            Remove-Item -Force -ErrorAction Stop $Path
            return
        } catch {
            if ($attempt -ge 4) { throw }
            Start-Sleep -Milliseconds 100
        }
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
    Write-Output "BAREMETAL_QEMU_SYSCALL_CONTROL_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SYSCALL_CONTROL_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_SYSCALL_CONTROL_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-syscall-control-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-syscall-control-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-syscall-control-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-syscall-control-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-syscall-control-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-syscall-control-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-syscall-control-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-syscall-control-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-syscall-control-probe.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
@"
pub const qemu_smoke: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii
    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-syscall-control-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for syscall-control probe runtime failed with exit code $LASTEXITCODE" }
    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for syscall-control probe PVH shim failed with exit code $LASTEXITCODE" }
    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for syscall-control probe PVH artifact failed with exit code $LASTEXITCODE" }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) { throw "Failed to resolve symbol table from $artifact using $nm" }

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
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
set $updated_token = 0
set $blocked_result = 0
set $disabled_result = 0
set $invoke_result = 0
set $invoke_tick = 0
set $missing_flags_result = 0
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
    set *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) = 1
    set *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__) = 0
    set *(unsigned short*)(0x__STATUS__+__STATUS_HEALTH_OFFSET__) = 200
    set *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_OFFSET__) = 0
    set *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) = 0
    set *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) = 0
    set *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) = 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_RESET_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 1
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 1
  end
  continue
end
if $stage == 1
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 1 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENABLED_OFFSET__) == 1 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENTRY_COUNT_OFFSET__) == 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_REGISTER_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 2
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __INITIAL_TOKEN__
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 2 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENTRY_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_ID_OFFSET__) == __SYSCALL_ID__ && *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_STATE_OFFSET__) == 1 && *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_FLAGS_OFFSET__) == 0 && *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_TOKEN_OFFSET__) == __INITIAL_TOKEN__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_REGISTER_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 3
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __UPDATED_TOKEN__
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 3 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENTRY_COUNT_OFFSET__) == 1 && *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_TOKEN_OFFSET__) == __UPDATED_TOKEN__ && *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_INVOKE_COUNT_OFFSET__) == 0
    set $updated_token = *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_TOKEN_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_SET_FLAGS_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 4
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __BLOCKED_FLAG__
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 4 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_FLAGS_OFFSET__) == __BLOCKED_FLAG__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_INVOKE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 5
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __INVOKE_ARG__
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 5 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == -17 && *(unsigned long long*)(0x__SYSCALL_STATE__+__SYSCALL_DISPATCH_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_ID_OFFSET__) == 0 && *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_INVOKE_COUNT_OFFSET__) == 0
    set $blocked_result = *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_DISABLE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 6
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 6 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENABLED_OFFSET__) == 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_SET_FLAGS_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 7
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 7 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENABLED_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_FLAGS_OFFSET__) == 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_INVOKE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 8
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __INVOKE_ARG__
    set $stage = 8
  end
  continue
end
if $stage == 8
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 8 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == -38 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENABLED_OFFSET__) == 0 && *(unsigned long long*)(0x__SYSCALL_STATE__+__SYSCALL_DISPATCH_COUNT_OFFSET__) == 0 && *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_INVOKE_COUNT_OFFSET__) == 0
    set $disabled_result = *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_ENABLE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 9
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 9
  end
  continue
end
if $stage == 9
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 9 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENABLED_OFFSET__) == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_INVOKE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 10
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __INVOKE_ARG__
    set $stage = 10
  end
  continue
end
if $stage == 10
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 10 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned long long*)(0x__SYSCALL_STATE__+__SYSCALL_DISPATCH_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_ID_OFFSET__) == __SYSCALL_ID__ && *(long long*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_RESULT_OFFSET__) == __EXPECTED_INVOKE_RESULT__ && *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_INVOKE_COUNT_OFFSET__) == 1 && *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_LAST_ARG_OFFSET__) == __INVOKE_ARG__ && *(long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_LAST_RESULT_OFFSET__) == __EXPECTED_INVOKE_RESULT__
    set $invoke_result = *(long long*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_RESULT_OFFSET__)
    set $invoke_tick = *(unsigned long long*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_INVOKE_TICK_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_UNREGISTER_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 11
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 11
  end
  continue
end
if $stage == 11
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 11 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_STATE_OFFSET__) == 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_SET_FLAGS_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 12
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __BLOCKED_FLAG__
    set $stage = 12
  end
  continue
end
if $stage == 12
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 12 && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == -2 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENTRY_COUNT_OFFSET__) == 0
    set $missing_flags_result = *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SYSCALL_UNREGISTER_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 13
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SYSCALL_ID__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 13
  end
  continue
end
if $stage == 13
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 13 && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __SYSCALL_UNREGISTER_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == -2 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == 1 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENABLED_OFFSET__) == 1 && *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned long long*)(0x__SYSCALL_STATE__+__SYSCALL_DISPATCH_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_ID_OFFSET__) == __SYSCALL_ID__ && *(long long*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_RESULT_OFFSET__) == __EXPECTED_INVOKE_RESULT__ && *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_STATE_OFFSET__) == 0 && *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_FLAGS_OFFSET__) == 0
    printf "HIT_AFTER_SYSCALL_CONTROL_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "STATUS_MODE=%u\n", *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    printf "UPDATED_TOKEN=%llu\n", $updated_token
    printf "BLOCKED_RESULT=%d\n", $blocked_result
    printf "DISABLED_RESULT=%d\n", $disabled_result
    printf "INVOKE_RESULT=%lld\n", $invoke_result
    printf "INVOKE_TICK=%llu\n", $invoke_tick
    printf "MISSING_FLAGS_RESULT=%d\n", $missing_flags_result
    printf "ENABLED=%u\n", *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENABLED_OFFSET__)
    printf "ENTRY_COUNT=%u\n", *(unsigned char*)(0x__SYSCALL_STATE__+__SYSCALL_ENTRY_COUNT_OFFSET__)
    printf "DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SYSCALL_STATE__+__SYSCALL_DISPATCH_COUNT_OFFSET__)
    printf "LAST_ID=%u\n", *(unsigned int*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_ID_OFFSET__)
    printf "STATE_LAST_RESULT=%lld\n", *(long long*)(0x__SYSCALL_STATE__+__SYSCALL_LAST_RESULT_OFFSET__)
    printf "ENTRY0_STATE=%u\n", *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_STATE_OFFSET__)
    printf "ENTRY0_FLAGS=%u\n", *(unsigned char*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_FLAGS_OFFSET__)
    printf "ENTRY0_INVOKE_COUNT=%llu\n", *(unsigned long long*)(0x__SYSCALL_ENTRIES__+__SYSCALL_ENTRY_INVOKE_COUNT_OFFSET__)
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
    Replace('__SYSCALL_STATE__', $syscallStateAddress).
    Replace('__SYSCALL_ENTRIES__', $syscallEntriesAddress).
    Replace('__SYSCALL_ENABLED_OFFSET__', [string]$syscallStateEnabledOffset).
    Replace('__SYSCALL_ENTRY_COUNT_OFFSET__', [string]$syscallStateEntryCountOffset).
    Replace('__SYSCALL_LAST_ID_OFFSET__', [string]$syscallStateLastIdOffset).
    Replace('__SYSCALL_DISPATCH_COUNT_OFFSET__', [string]$syscallStateDispatchCountOffset).
    Replace('__SYSCALL_LAST_INVOKE_TICK_OFFSET__', [string]$syscallStateLastInvokeTickOffset).
    Replace('__SYSCALL_LAST_RESULT_OFFSET__', [string]$syscallStateLastResultOffset).
    Replace('__SYSCALL_ENTRY_ID_OFFSET__', [string]$syscallEntryIdOffset).
    Replace('__SYSCALL_ENTRY_STATE_OFFSET__', [string]$syscallEntryStateOffset).
    Replace('__SYSCALL_ENTRY_FLAGS_OFFSET__', [string]$syscallEntryFlagsOffset).
    Replace('__SYSCALL_ENTRY_TOKEN_OFFSET__', [string]$syscallEntryTokenOffset).
    Replace('__SYSCALL_ENTRY_INVOKE_COUNT_OFFSET__', [string]$syscallEntryInvokeCountOffset).
    Replace('__SYSCALL_ENTRY_LAST_ARG_OFFSET__', [string]$syscallEntryLastArgOffset).
    Replace('__SYSCALL_ENTRY_LAST_RESULT_OFFSET__', [string]$syscallEntryLastResultOffset).
    Replace('__SYSCALL_RESET_OPCODE__', [string]$syscallResetOpcode).
    Replace('__SYSCALL_REGISTER_OPCODE__', [string]$syscallRegisterOpcode).
    Replace('__SYSCALL_UNREGISTER_OPCODE__', [string]$syscallUnregisterOpcode).
    Replace('__SYSCALL_INVOKE_OPCODE__', [string]$syscallInvokeOpcode).
    Replace('__SYSCALL_ENABLE_OPCODE__', [string]$syscallEnableOpcode).
    Replace('__SYSCALL_DISABLE_OPCODE__', [string]$syscallDisableOpcode).
    Replace('__SYSCALL_SET_FLAGS_OPCODE__', [string]$syscallSetFlagsOpcode).
    Replace('__SYSCALL_ID__', [string]$syscallId).
    Replace('__INITIAL_TOKEN__', [string]$initialToken).
    Replace('__UPDATED_TOKEN__', [string]$updatedToken).
    Replace('__INVOKE_ARG__', [string]$invokeArg).
    Replace('__BLOCKED_FLAG__', [string]$blockedFlag).
    Replace('__EXPECTED_INVOKE_RESULT__', [string]$expectedInvokeResult)

Set-Content -Path $gdbScript -Value $gdbContent -Encoding Ascii -NoNewline

$qemuArgs = @(
    "-accel", "tcg",
    "-machine", "q35",
    "-cpu", "max",
    "-nographic",
    "-monitor", "none",
    "-serial", "none",
    "-display", "none",
    "-S",
    "-gdb", "tcp::$GdbPort",
    "-kernel", $artifact
)

$qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -PassThru
try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        if ($qemuProcess.HasExited) {
            $stderrText = if (Test-Path $qemuStderr) { Get-Content $qemuStderr -Raw } else { "" }
            $stdoutText = if (Test-Path $qemuStdout) { Get-Content $qemuStdout -Raw } else { "" }
            throw "QEMU exited before GDB completed. stdout: $stdoutText stderr: $stderrText"
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

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("--quiet", "--batch", "-x", $gdbScript) -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr -PassThru
    if (-not $gdbProcess.WaitForExit($TimeoutSeconds * 1000)) {
        try { $gdbProcess.Kill() } catch {}
        throw "Timed out waiting for GDB syscall-control probe"
    }

    $gdbOutput = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
    $gdbError = if (Test-Path $gdbStderr) { Get-Content $gdbStderr -Raw } else { "" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProcess.ExitCode)) { 0 } else { [int]$gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        throw "GDB syscall-control probe failed with exit code $gdbExitCode. stdout: $gdbOutput stderr: $gdbError"
    }

    foreach ($requiredMarker in @("HIT_START", "HIT_AFTER_SYSCALL_CONTROL_PROBE")) {
        if ($gdbOutput -notmatch [regex]::Escape($requiredMarker)) {
            throw "Missing expected marker '$requiredMarker' in GDB output. stdout: $gdbOutput stderr: $gdbError"
        }
    }

    $expectations = @{
        "ACK" = 13
        "LAST_OPCODE" = $syscallUnregisterOpcode
        "LAST_RESULT" = -2
        "STATUS_MODE" = 1
        "UPDATED_TOKEN" = $updatedToken
        "BLOCKED_RESULT" = -17
        "DISABLED_RESULT" = -38
        "INVOKE_RESULT" = $expectedInvokeResult
        "MISSING_FLAGS_RESULT" = -2
        "ENABLED" = 1
        "ENTRY_COUNT" = 0
        "DISPATCH_COUNT" = 1
        "LAST_ID" = $syscallId
        "STATE_LAST_RESULT" = $expectedInvokeResult
        "ENTRY0_STATE" = 0
        "ENTRY0_FLAGS" = 0
        "ENTRY0_INVOKE_COUNT" = 0
    }

    foreach ($name in $expectations.Keys) {
        $actual = Extract-IntValue -Text $gdbOutput -Name $name
        if ($null -eq $actual) {
            throw "Missing expected field '$name' in probe output. stdout: $gdbOutput stderr: $gdbError"
        }
        if ($actual -ne [int64]$expectations[$name]) {
            throw "Unexpected value for $name. Expected $($expectations[$name]), got $actual. stdout: $gdbOutput stderr: $gdbError"
        }
    }

    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    if ($null -eq $ticks) { throw "Missing TICKS in probe output. stdout: $gdbOutput stderr: $gdbError" }
    if ($ticks -lt 13) { throw "Unexpected TICKS value. Expected at least 13, got $ticks. stdout: $gdbOutput stderr: $gdbError" }
    $invokeTick = Extract-IntValue -Text $gdbOutput -Name "INVOKE_TICK"
    if ($null -eq $invokeTick) { throw "Missing INVOKE_TICK in probe output. stdout: $gdbOutput stderr: $gdbError" }
    if ($invokeTick -le 0) { throw "Unexpected INVOKE_TICK value. Expected > 0, got $invokeTick. stdout: $gdbOutput stderr: $gdbError" }

    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_SYSCALL_CONTROL_PROBE=pass"
    $gdbOutput.TrimEnd()
} finally {
    if ($null -ne $qemuProcess -and -not $qemuProcess.HasExited) {
        try { $qemuProcess.Kill() } catch {}
        try { $qemuProcess.WaitForExit() } catch {}
    }
}
