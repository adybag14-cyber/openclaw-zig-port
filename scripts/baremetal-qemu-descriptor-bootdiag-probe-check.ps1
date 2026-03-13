param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1245
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$reinitDescriptorTablesOpcode = 9
$loadDescriptorTablesOpcode = 10
$setBootPhaseOpcode = 16
$resetBootDiagnosticsOpcode = 17
$captureStackPointerOpcode = 18
$bootPhaseInit = 1
$bootPhaseRuntime = 2

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$bootDiagPhaseOffset = 6
$bootDiagBootSeqOffset = 8
$bootDiagLastCommandSeqOffset = 12
$bootDiagLastCommandTickOffset = 16
$bootDiagLastTickObservedOffset = 24
$bootDiagStackPointerSnapshotOffset = 32
$bootDiagPhaseChangesOffset = 40

$interruptDescriptorReadyOffset = 0
$interruptDescriptorLoadedOffset = 1
$interruptLoadAttemptsOffset = 4
$interruptLoadSuccessesOffset = 8
$interruptDescriptorInitCountOffset = 12

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
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-descriptor-bootdiag-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-descriptor-bootdiag-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-descriptor-bootdiag-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-descriptor-bootdiag-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-descriptor-bootdiag-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-descriptor-bootdiag-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-descriptor-bootdiag-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-descriptor-bootdiag-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-descriptor-bootdiag-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for descriptor-bootdiag probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for descriptor-bootdiag probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for descriptor-bootdiag probe PVH artifact failed with exit code $LASTEXITCODE"
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
$bootDiagnosticsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_diagnostics$' -SymbolName "baremetal_main.boot_diagnostics"
$interruptStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_state$' -SymbolName "baremetal.x86_bootstrap.interrupt_state"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout -ErrorAction SilentlyContinue }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr -ErrorAction SilentlyContinue }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout -ErrorAction SilentlyContinue }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr -ErrorAction SilentlyContinue }

@"
set pagination off
set confirm off
set `$stage = 0
set `$boot_seq_before = 0
set `$descriptor_ready_before = 0
set `$descriptor_loaded_before = 0
set `$load_attempts_before = 0
set `$load_successes_before = 0
set `$descriptor_init_before = 0
set `$boot_seq_after_reset = 0
set `$phase_after_reset = 0
set `$last_command_seq_after_reset = 0
set `$phase_changes_after_reset = 0
set `$stack_snapshot_after_capture = 0
set `$last_command_seq_after_capture = 0
set `$phase_after_set_init = 0
set `$last_command_seq_after_set_init = 0
set `$phase_changes_after_set_init = 0
set `$invalid_result = 0
set `$phase_after_invalid = 0
set `$phase_changes_after_invalid = 0
set `$descriptor_ready_after_reinit = 0
set `$descriptor_loaded_after_reinit = 0
set `$descriptor_init_after_reinit = 0
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START\n"
continue
end
break *0x$spinPauseAddress
commands
silent
if `$stage == 0
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 0 && *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset) == 1 && *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset) == 1
    set `$boot_seq_before = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagBootSeqOffset)
    set `$descriptor_ready_before = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset)
    set `$descriptor_loaded_before = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset)
    set `$load_attempts_before = *(unsigned int*)(0x$interruptStateAddress+$interruptLoadAttemptsOffset)
    set `$load_successes_before = *(unsigned int*)(0x$interruptStateAddress+$interruptLoadSuccessesOffset)
    set `$descriptor_init_before = *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetBootDiagnosticsOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 1
  end
  continue
end
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1
    set `$boot_seq_after_reset = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagBootSeqOffset)
    set `$phase_after_reset = *(unsigned char*)(0x$bootDiagnosticsAddress+$bootDiagPhaseOffset)
    set `$last_command_seq_after_reset = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagLastCommandSeqOffset)
    set `$phase_changes_after_reset = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagPhaseChangesOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $captureStackPointerOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned long long*)(0x$bootDiagnosticsAddress+$bootDiagStackPointerSnapshotOffset) != 0
    set `$stack_snapshot_after_capture = *(unsigned long long*)(0x$bootDiagnosticsAddress+$bootDiagStackPointerSnapshotOffset)
    set `$last_command_seq_after_capture = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagLastCommandSeqOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setBootPhaseOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $bootPhaseInit
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3 && *(unsigned char*)(0x$bootDiagnosticsAddress+$bootDiagPhaseOffset) == $bootPhaseInit
    set `$phase_after_set_init = *(unsigned char*)(0x$bootDiagnosticsAddress+$bootDiagPhaseOffset)
    set `$last_command_seq_after_set_init = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagLastCommandSeqOffset)
    set `$phase_changes_after_set_init = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagPhaseChangesOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setBootPhaseOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 99
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == -22
    set `$invalid_result = *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    set `$phase_after_invalid = *(unsigned char*)(0x$bootDiagnosticsAddress+$bootDiagPhaseOffset)
    set `$phase_changes_after_invalid = *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagPhaseChangesOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $reinitDescriptorTablesOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset) == (`$descriptor_init_before + 1)
    set `$descriptor_ready_after_reinit = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset)
    set `$descriptor_loaded_after_reinit = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset)
    set `$descriptor_init_after_reinit = *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $loadDescriptorTablesOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$interruptStateAddress+$interruptLoadAttemptsOffset) == (`$load_attempts_before + 1) && *(unsigned int*)(0x$interruptStateAddress+$interruptLoadSuccessesOffset) == (`$load_successes_before + 1)
    printf "AFTER_DESCRIPTOR_BOOTDIAG\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
    printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    printf "BOOT_SEQ_BEFORE=%u\n", `$boot_seq_before
    printf "BOOT_SEQ_AFTER_RESET=%u\n", `$boot_seq_after_reset
    printf "PHASE_AFTER_RESET=%u\n", `$phase_after_reset
    printf "LAST_COMMAND_SEQ_AFTER_RESET=%u\n", `$last_command_seq_after_reset
    printf "PHASE_CHANGES_AFTER_RESET=%u\n", `$phase_changes_after_reset
    printf "STACK_SNAPSHOT_AFTER_CAPTURE=%llu\n", `$stack_snapshot_after_capture
    printf "LAST_COMMAND_SEQ_AFTER_CAPTURE=%u\n", `$last_command_seq_after_capture
    printf "PHASE_AFTER_SET_INIT=%u\n", `$phase_after_set_init
    printf "LAST_COMMAND_SEQ_AFTER_SET_INIT=%u\n", `$last_command_seq_after_set_init
    printf "PHASE_CHANGES_AFTER_SET_INIT=%u\n", `$phase_changes_after_set_init
    printf "INVALID_RESULT=%d\n", `$invalid_result
    printf "PHASE_AFTER_INVALID=%u\n", `$phase_after_invalid
    printf "PHASE_CHANGES_AFTER_INVALID=%u\n", `$phase_changes_after_invalid
    printf "DESCRIPTOR_READY_BEFORE=%u\n", `$descriptor_ready_before
    printf "DESCRIPTOR_LOADED_BEFORE=%u\n", `$descriptor_loaded_before
    printf "LOAD_ATTEMPTS_BEFORE=%u\n", `$load_attempts_before
    printf "LOAD_SUCCESSES_BEFORE=%u\n", `$load_successes_before
    printf "DESCRIPTOR_INIT_BEFORE=%u\n", `$descriptor_init_before
    printf "DESCRIPTOR_READY_AFTER_REINIT=%u\n", `$descriptor_ready_after_reinit
    printf "DESCRIPTOR_LOADED_AFTER_REINIT=%u\n", `$descriptor_loaded_after_reinit
    printf "DESCRIPTOR_INIT_AFTER_REINIT=%u\n", `$descriptor_init_after_reinit
    printf "BOOT_PHASE_FINAL=%u\n", *(unsigned char*)(0x$bootDiagnosticsAddress+$bootDiagPhaseOffset)
    printf "BOOT_SEQ_FINAL=%u\n", *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagBootSeqOffset)
    printf "LAST_COMMAND_SEQ_FINAL=%u\n", *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagLastCommandSeqOffset)
    printf "LAST_COMMAND_TICK_FINAL=%llu\n", *(unsigned long long*)(0x$bootDiagnosticsAddress+$bootDiagLastCommandTickOffset)
    printf "LAST_TICK_OBSERVED_FINAL=%llu\n", *(unsigned long long*)(0x$bootDiagnosticsAddress+$bootDiagLastTickObservedOffset)
    printf "STACK_SNAPSHOT_FINAL=%llu\n", *(unsigned long long*)(0x$bootDiagnosticsAddress+$bootDiagStackPointerSnapshotOffset)
    printf "PHASE_CHANGES_FINAL=%u\n", *(unsigned int*)(0x$bootDiagnosticsAddress+$bootDiagPhaseChangesOffset)
    printf "DESCRIPTOR_READY_FINAL=%u\n", *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset)
    printf "DESCRIPTOR_LOADED_FINAL=%u\n", *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset)
    printf "LOAD_ATTEMPTS_FINAL=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptLoadAttemptsOffset)
    printf "LOAD_SUCCESSES_FINAL=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptLoadSuccessesOffset)
    printf "DESCRIPTOR_INIT_FINAL=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset)
    quit
  end
  continue
end
continue
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
$hitAfterDescriptorBootdiag = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$bootSeqBefore = $null
$bootSeqAfterReset = $null
$phaseAfterReset = $null
$lastCommandSeqAfterReset = $null
$phaseChangesAfterReset = $null
$stackSnapshotAfterCapture = $null
$lastCommandSeqAfterCapture = $null
$phaseAfterSetInit = $null
$lastCommandSeqAfterSetInit = $null
$phaseChangesAfterSetInit = $null
$invalidResult = $null
$phaseAfterInvalid = $null
$phaseChangesAfterInvalid = $null
$descriptorReadyBefore = $null
$descriptorLoadedBefore = $null
$loadAttemptsBefore = $null
$loadSuccessesBefore = $null
$descriptorInitBefore = $null
$descriptorReadyAfterReinit = $null
$descriptorLoadedAfterReinit = $null
$descriptorInitAfterReinit = $null
$bootPhaseFinal = $null
$bootSeqFinal = $null
$lastCommandSeqFinal = $null
$lastCommandTickFinal = $null
$lastTickObservedFinal = $null
$stackSnapshotFinal = $null
$phaseChangesFinal = $null
$descriptorReadyFinal = $null
$descriptorLoadedFinal = $null
$loadAttemptsFinal = $null
$loadSuccessesFinal = $null
$descriptorInitFinal = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterDescriptorBootdiag = $out -match "AFTER_DESCRIPTOR_BOOTDIAG"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $bootSeqBefore = Extract-IntValue -Text $out -Name "BOOT_SEQ_BEFORE"
    $bootSeqAfterReset = Extract-IntValue -Text $out -Name "BOOT_SEQ_AFTER_RESET"
    $phaseAfterReset = Extract-IntValue -Text $out -Name "PHASE_AFTER_RESET"
    $lastCommandSeqAfterReset = Extract-IntValue -Text $out -Name "LAST_COMMAND_SEQ_AFTER_RESET"
    $phaseChangesAfterReset = Extract-IntValue -Text $out -Name "PHASE_CHANGES_AFTER_RESET"
    $stackSnapshotAfterCapture = Extract-IntValue -Text $out -Name "STACK_SNAPSHOT_AFTER_CAPTURE"
    $lastCommandSeqAfterCapture = Extract-IntValue -Text $out -Name "LAST_COMMAND_SEQ_AFTER_CAPTURE"
    $phaseAfterSetInit = Extract-IntValue -Text $out -Name "PHASE_AFTER_SET_INIT"
    $lastCommandSeqAfterSetInit = Extract-IntValue -Text $out -Name "LAST_COMMAND_SEQ_AFTER_SET_INIT"
    $phaseChangesAfterSetInit = Extract-IntValue -Text $out -Name "PHASE_CHANGES_AFTER_SET_INIT"
    $invalidResult = Extract-IntValue -Text $out -Name "INVALID_RESULT"
    $phaseAfterInvalid = Extract-IntValue -Text $out -Name "PHASE_AFTER_INVALID"
    $phaseChangesAfterInvalid = Extract-IntValue -Text $out -Name "PHASE_CHANGES_AFTER_INVALID"
    $descriptorReadyBefore = Extract-IntValue -Text $out -Name "DESCRIPTOR_READY_BEFORE"
    $descriptorLoadedBefore = Extract-IntValue -Text $out -Name "DESCRIPTOR_LOADED_BEFORE"
    $loadAttemptsBefore = Extract-IntValue -Text $out -Name "LOAD_ATTEMPTS_BEFORE"
    $loadSuccessesBefore = Extract-IntValue -Text $out -Name "LOAD_SUCCESSES_BEFORE"
    $descriptorInitBefore = Extract-IntValue -Text $out -Name "DESCRIPTOR_INIT_BEFORE"
    $descriptorReadyAfterReinit = Extract-IntValue -Text $out -Name "DESCRIPTOR_READY_AFTER_REINIT"
    $descriptorLoadedAfterReinit = Extract-IntValue -Text $out -Name "DESCRIPTOR_LOADED_AFTER_REINIT"
    $descriptorInitAfterReinit = Extract-IntValue -Text $out -Name "DESCRIPTOR_INIT_AFTER_REINIT"
    $bootPhaseFinal = Extract-IntValue -Text $out -Name "BOOT_PHASE_FINAL"
    $bootSeqFinal = Extract-IntValue -Text $out -Name "BOOT_SEQ_FINAL"
    $lastCommandSeqFinal = Extract-IntValue -Text $out -Name "LAST_COMMAND_SEQ_FINAL"
    $lastCommandTickFinal = Extract-IntValue -Text $out -Name "LAST_COMMAND_TICK_FINAL"
    $lastTickObservedFinal = Extract-IntValue -Text $out -Name "LAST_TICK_OBSERVED_FINAL"
    $stackSnapshotFinal = Extract-IntValue -Text $out -Name "STACK_SNAPSHOT_FINAL"
    $phaseChangesFinal = Extract-IntValue -Text $out -Name "PHASE_CHANGES_FINAL"
    $descriptorReadyFinal = Extract-IntValue -Text $out -Name "DESCRIPTOR_READY_FINAL"
    $descriptorLoadedFinal = Extract-IntValue -Text $out -Name "DESCRIPTOR_LOADED_FINAL"
    $loadAttemptsFinal = Extract-IntValue -Text $out -Name "LOAD_ATTEMPTS_FINAL"
    $loadSuccessesFinal = Extract-IntValue -Text $out -Name "LOAD_SUCCESSES_FINAL"
    $descriptorInitFinal = Extract-IntValue -Text $out -Name "DESCRIPTOR_INIT_FINAL"
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
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_BOOT_DIAG_ADDR=0x$bootDiagnosticsAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_INTERRUPT_STATE_ADDR=0x$interruptStateAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_HIT_AFTER_DESCRIPTOR_BOOTDIAG=$hitAfterDescriptorBootdiag"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_BOOT_SEQ_BEFORE=$bootSeqBefore"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_BOOT_SEQ_AFTER_RESET=$bootSeqAfterReset"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_PHASE_AFTER_RESET=$phaseAfterReset"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_COMMAND_SEQ_AFTER_RESET=$lastCommandSeqAfterReset"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_PHASE_CHANGES_AFTER_RESET=$phaseChangesAfterReset"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_STACK_SNAPSHOT_AFTER_CAPTURE=$stackSnapshotAfterCapture"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_COMMAND_SEQ_AFTER_CAPTURE=$lastCommandSeqAfterCapture"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_PHASE_AFTER_SET_INIT=$phaseAfterSetInit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_COMMAND_SEQ_AFTER_SET_INIT=$lastCommandSeqAfterSetInit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_PHASE_CHANGES_AFTER_SET_INIT=$phaseChangesAfterSetInit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_INVALID_RESULT=$invalidResult"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_PHASE_AFTER_INVALID=$phaseAfterInvalid"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_PHASE_CHANGES_AFTER_INVALID=$phaseChangesAfterInvalid"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_READY_BEFORE=$descriptorReadyBefore"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_LOADED_BEFORE=$descriptorLoadedBefore"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LOAD_ATTEMPTS_BEFORE=$loadAttemptsBefore"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LOAD_SUCCESSES_BEFORE=$loadSuccessesBefore"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_INIT_BEFORE=$descriptorInitBefore"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_READY_AFTER_REINIT=$descriptorReadyAfterReinit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_LOADED_AFTER_REINIT=$descriptorLoadedAfterReinit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_INIT_AFTER_REINIT=$descriptorInitAfterReinit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_BOOT_PHASE_FINAL=$bootPhaseFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_BOOT_SEQ_FINAL=$bootSeqFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_COMMAND_SEQ_FINAL=$lastCommandSeqFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_COMMAND_TICK_FINAL=$lastCommandTickFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LAST_TICK_OBSERVED_FINAL=$lastTickObservedFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_STACK_SNAPSHOT_FINAL=$stackSnapshotFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_PHASE_CHANGES_FINAL=$phaseChangesFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_READY_FINAL=$descriptorReadyFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_LOADED_FINAL=$descriptorLoadedFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LOAD_ATTEMPTS_FINAL=$loadAttemptsFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_LOAD_SUCCESSES_FINAL=$loadSuccessesFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_DESCRIPTOR_INIT_FINAL=$descriptorInitFinal"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and
    $hitAfterDescriptorBootdiag -and
    (-not $timedOut) -and
    $ack -eq 6 -and
    $lastOpcode -eq $loadDescriptorTablesOpcode -and
    $lastResult -eq 0 -and
    $mailboxOpcode -eq $loadDescriptorTablesOpcode -and
    $mailboxSeq -eq 6 -and
    $descriptorReadyBefore -eq 1 -and
    $descriptorLoadedBefore -eq 1 -and
    $loadAttemptsBefore -ge 1 -and
    $loadSuccessesBefore -ge 1 -and
    $descriptorInitBefore -ge 1 -and
    $bootSeqAfterReset -eq ($bootSeqBefore + 1) -and
    $phaseAfterReset -eq $bootPhaseRuntime -and
    $lastCommandSeqAfterReset -eq 1 -and
    $phaseChangesAfterReset -eq 0 -and
    $stackSnapshotAfterCapture -gt 0 -and
    $lastCommandSeqAfterCapture -eq 2 -and
    $phaseAfterSetInit -eq $bootPhaseInit -and
    $lastCommandSeqAfterSetInit -eq 3 -and
    $phaseChangesAfterSetInit -eq 1 -and
    $invalidResult -eq -22 -and
    $phaseAfterInvalid -eq $bootPhaseInit -and
    $phaseChangesAfterInvalid -eq 1 -and
    $descriptorReadyAfterReinit -eq 1 -and
    $descriptorLoadedAfterReinit -eq 1 -and
    $descriptorInitAfterReinit -eq ($descriptorInitBefore + 1) -and
    $bootPhaseFinal -eq $bootPhaseInit -and
    $bootSeqFinal -eq $bootSeqAfterReset -and
    $lastCommandSeqFinal -eq 6 -and
    $lastCommandTickFinal -gt 0 -and
    $lastTickObservedFinal -ge $lastCommandTickFinal -and
    $stackSnapshotFinal -eq $stackSnapshotAfterCapture -and
    $phaseChangesFinal -eq 1 -and
    $descriptorReadyFinal -eq 1 -and
    $descriptorLoadedFinal -eq 1 -and
    $loadAttemptsFinal -eq ($loadAttemptsBefore + 1) -and
    $loadSuccessesFinal -eq ($loadSuccessesBefore + 1) -and
    $descriptorInitFinal -eq $descriptorInitAfterReinit -and
    $ticks -ge $lastCommandTickFinal
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_DESCRIPTOR_BOOTDIAG_PROBE=fail"
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

