param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1265
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$wakeQueueClearOpcode = 44
$setHealthCodeOpcode = 1
$setModeOpcode = 4
$resetCommandResultCountersOpcode = 23
$wakeQueuePopOpcode = 54
$unsupportedOpcode = 65535

$healthCode = 123
$invalidMode = 77
$modeRunning = 1
$expectedStatusHealthCode = 200
$expectedPreAck = 5
$expectedPostAck = 6
$expectedPreTickFloor = 4
$expectedPostTickFloor = 5
$expectedOtherErrorResult = -2

$statusModeOffset = 6
$statusTicksOffset = 8
$statusLastHealthCodeOffset = 16
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$commandResultOkCountOffset = 0
$commandResultInvalidCountOffset = 4
$commandResultNotSupportedCountOffset = 8
$commandResultOtherErrorCountOffset = 12
$commandResultTotalCountOffset = 16
$commandResultLastResultOffset = 24
$commandResultLastOpcodeOffset = 28
$commandResultLastSeqOffset = 32

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
    foreach ($name in @("gdb", "gdb.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
    }

    return $null
}

function Resolve-NmExecutable {
    foreach ($name in @("llvm-nm", "llvm-nm.exe", "nm", "nm.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\llvm-nm.exe")) {
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
    foreach ($name in @("clang", "clang.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\clang.exe")) {
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
    foreach ($name in @("lld", "lld.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\lld.exe")) {
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
    Write-Output "BAREMETAL_QEMU_COMMAND_RESULT_COUNTERS_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_COMMAND_RESULT_COUNTERS_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_COMMAND_RESULT_COUNTERS_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-command-result-counters-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-command-result-counters-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-command-result-counters-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-command-result-counters-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-command-result-counters-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-command-result-counters-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-command-result-counters-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-command-result-counters-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-command-result-counters-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-command-result-counters-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for command-result-counters probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for command-result-counters probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for command-result-counters probe PVH artifact failed with exit code $LASTEXITCODE"
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
$commandResultCountersAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_result_counters$' -SymbolName "baremetal_main.command_result_counters"
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
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
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
    set *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastHealthCodeOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset) = 0
    set *(short*)(0x$statusAddress+$statusLastCommandResultOffset) = 0
    set *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOkCountOffset) = 0
    set *(unsigned int*)(0x$commandResultCountersAddress+$commandResultInvalidCountOffset) = 0
    set *(unsigned int*)(0x$commandResultCountersAddress+$commandResultNotSupportedCountOffset) = 0
    set *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOtherErrorCountOffset) = 0
    set *(unsigned int*)(0x$commandResultCountersAddress+$commandResultTotalCountOffset) = 0
    set *(short*)(0x$commandResultCountersAddress+$commandResultLastResultOffset) = 0
    set *(unsigned short*)(0x$commandResultCountersAddress+$commandResultLastOpcodeOffset) = 0
    set *(unsigned int*)(0x$commandResultCountersAddress+$commandResultLastSeqOffset) = 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setHealthCodeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $healthCode
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setModeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $invalidMode
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $unsupportedOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    printf "HIT_BEFORE_RESET\n"
    printf "PRE_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "PRE_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "PRE_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "PRE_TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "PRE_MODE=%u\n", *(unsigned char*)(0x$statusAddress+$statusModeOffset)
    printf "PRE_HEALTH_CODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastHealthCodeOffset)
    printf "PRE_COUNTER_OK=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOkCountOffset)
    printf "PRE_COUNTER_INVALID=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultInvalidCountOffset)
    printf "PRE_COUNTER_NOT_SUPPORTED=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultNotSupportedCountOffset)
    printf "PRE_COUNTER_OTHER=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOtherErrorCountOffset)
    printf "PRE_COUNTER_TOTAL=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultTotalCountOffset)
    printf "PRE_COUNTER_LAST_RESULT=%d\n", *(short*)(0x$commandResultCountersAddress+$commandResultLastResultOffset)
    printf "PRE_COUNTER_LAST_OPCODE=%u\n", *(unsigned short*)(0x$commandResultCountersAddress+$commandResultLastOpcodeOffset)
    printf "PRE_COUNTER_LAST_SEQ=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultLastSeqOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetCommandResultCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6
    printf "HIT_AFTER_RESET\n"
    printf "POST_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "POST_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "POST_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "POST_TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "POST_MODE=%u\n", *(unsigned char*)(0x$statusAddress+$statusModeOffset)
    printf "POST_HEALTH_CODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastHealthCodeOffset)
    printf "POST_COUNTER_OK=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOkCountOffset)
    printf "POST_COUNTER_INVALID=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultInvalidCountOffset)
    printf "POST_COUNTER_NOT_SUPPORTED=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultNotSupportedCountOffset)
    printf "POST_COUNTER_OTHER=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOtherErrorCountOffset)
    printf "POST_COUNTER_TOTAL=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultTotalCountOffset)
    printf "POST_COUNTER_LAST_RESULT=%d\n", *(short*)(0x$commandResultCountersAddress+$commandResultLastResultOffset)
    printf "POST_COUNTER_LAST_OPCODE=%u\n", *(unsigned short*)(0x$commandResultCountersAddress+$commandResultLastOpcodeOffset)
    printf "POST_COUNTER_LAST_SEQ=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultLastSeqOffset)
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

$gdbOutput = if (Test-Path $gdbStdout) { Get-Content -Raw $gdbStdout } else { "" }
$gdbError = if (Test-Path $gdbStderr) { Get-Content -Raw $gdbStderr } else { "" }

if ($timedOut) {
    throw "GDB timed out while probing command-result counters. stdout: $gdbOutput stderr: $gdbError"
}

$hitStart = $gdbOutput -match "HIT_START"
$hitBeforeReset = $gdbOutput -match "HIT_BEFORE_RESET"
$hitAfterReset = $gdbOutput -match "HIT_AFTER_RESET"

if (-not $hitStart -or -not $hitBeforeReset -or -not $hitAfterReset) {
    throw "Command-result counters probe did not reach all checkpoints. stdout: $gdbOutput stderr: $gdbError"
}

$preAck = Extract-IntValue -Text $gdbOutput -Name "PRE_ACK"
$preLastOpcode = Extract-IntValue -Text $gdbOutput -Name "PRE_LAST_OPCODE"
$preLastResult = Extract-IntValue -Text $gdbOutput -Name "PRE_LAST_RESULT"
$preTicks = Extract-IntValue -Text $gdbOutput -Name "PRE_TICKS"
$preMode = Extract-IntValue -Text $gdbOutput -Name "PRE_MODE"
$preHealthCode = Extract-IntValue -Text $gdbOutput -Name "PRE_HEALTH_CODE"
$preCounterOk = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_OK"
$preCounterInvalid = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_INVALID"
$preCounterNotSupported = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_NOT_SUPPORTED"
$preCounterOther = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_OTHER"
$preCounterTotal = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_TOTAL"
$preCounterLastResult = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_LAST_RESULT"
$preCounterLastOpcode = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_LAST_OPCODE"
$preCounterLastSeq = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNTER_LAST_SEQ"

$postAck = Extract-IntValue -Text $gdbOutput -Name "POST_ACK"
$postLastOpcode = Extract-IntValue -Text $gdbOutput -Name "POST_LAST_OPCODE"
$postLastResult = Extract-IntValue -Text $gdbOutput -Name "POST_LAST_RESULT"
$postTicks = Extract-IntValue -Text $gdbOutput -Name "POST_TICKS"
$postMode = Extract-IntValue -Text $gdbOutput -Name "POST_MODE"
$postHealthCode = Extract-IntValue -Text $gdbOutput -Name "POST_HEALTH_CODE"
$postCounterOk = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_OK"
$postCounterInvalid = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_INVALID"
$postCounterNotSupported = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_NOT_SUPPORTED"
$postCounterOther = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_OTHER"
$postCounterTotal = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_TOTAL"
$postCounterLastResult = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_LAST_RESULT"
$postCounterLastOpcode = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_LAST_OPCODE"
$postCounterLastSeq = Extract-IntValue -Text $gdbOutput -Name "POST_COUNTER_LAST_SEQ"

$preExpectations = @{
    PRE_ACK = $expectedPreAck
    PRE_LAST_OPCODE = $wakeQueuePopOpcode
    PRE_LAST_RESULT = $expectedOtherErrorResult
    PRE_MODE = $modeRunning
    PRE_HEALTH_CODE = $expectedStatusHealthCode
    PRE_COUNTER_OK = 1
    PRE_COUNTER_INVALID = 1
    PRE_COUNTER_NOT_SUPPORTED = 1
    PRE_COUNTER_OTHER = 1
    PRE_COUNTER_TOTAL = 4
    PRE_COUNTER_LAST_RESULT = $expectedOtherErrorResult
    PRE_COUNTER_LAST_OPCODE = $wakeQueuePopOpcode
    PRE_COUNTER_LAST_SEQ = 5
}

$postExpectations = @{
    POST_ACK = $expectedPostAck
    POST_LAST_OPCODE = $resetCommandResultCountersOpcode
    POST_LAST_RESULT = 0
    POST_MODE = $modeRunning
    POST_HEALTH_CODE = $expectedStatusHealthCode
    POST_COUNTER_OK = 1
    POST_COUNTER_INVALID = 0
    POST_COUNTER_NOT_SUPPORTED = 0
    POST_COUNTER_OTHER = 0
    POST_COUNTER_TOTAL = 1
    POST_COUNTER_LAST_RESULT = 0
    POST_COUNTER_LAST_OPCODE = $resetCommandResultCountersOpcode
    POST_COUNTER_LAST_SEQ = 6
}

$actuals = @{
    PRE_ACK = $preAck
    PRE_LAST_OPCODE = $preLastOpcode
    PRE_LAST_RESULT = $preLastResult
    PRE_MODE = $preMode
    PRE_HEALTH_CODE = $preHealthCode
    PRE_COUNTER_OK = $preCounterOk
    PRE_COUNTER_INVALID = $preCounterInvalid
    PRE_COUNTER_NOT_SUPPORTED = $preCounterNotSupported
    PRE_COUNTER_OTHER = $preCounterOther
    PRE_COUNTER_TOTAL = $preCounterTotal
    PRE_COUNTER_LAST_RESULT = $preCounterLastResult
    PRE_COUNTER_LAST_OPCODE = $preCounterLastOpcode
    PRE_COUNTER_LAST_SEQ = $preCounterLastSeq
    POST_ACK = $postAck
    POST_LAST_OPCODE = $postLastOpcode
    POST_LAST_RESULT = $postLastResult
    POST_MODE = $postMode
    POST_HEALTH_CODE = $postHealthCode
    POST_COUNTER_OK = $postCounterOk
    POST_COUNTER_INVALID = $postCounterInvalid
    POST_COUNTER_NOT_SUPPORTED = $postCounterNotSupported
    POST_COUNTER_OTHER = $postCounterOther
    POST_COUNTER_TOTAL = $postCounterTotal
    POST_COUNTER_LAST_RESULT = $postCounterLastResult
    POST_COUNTER_LAST_OPCODE = $postCounterLastOpcode
    POST_COUNTER_LAST_SEQ = $postCounterLastSeq
}

foreach ($name in $preExpectations.Keys + $postExpectations.Keys) {
    if ($null -eq $actuals[$name]) {
        throw "Missing expected field '$name' in command-result counters probe output. stdout: $gdbOutput stderr: $gdbError"
    }
}

foreach ($name in $preExpectations.Keys) {
    if ([int64]$actuals[$name] -ne [int64]$preExpectations[$name]) {
        throw "Unexpected value for $name. Expected $($preExpectations[$name]), got $($actuals[$name]). stdout: $gdbOutput stderr: $gdbError"
    }
}

foreach ($name in $postExpectations.Keys) {
    if ([int64]$actuals[$name] -ne [int64]$postExpectations[$name]) {
        throw "Unexpected value for $name. Expected $($postExpectations[$name]), got $($actuals[$name]). stdout: $gdbOutput stderr: $gdbError"
    }
}

if ($null -eq $preTicks -or $preTicks -lt $expectedPreTickFloor) {
    throw "Unexpected PRE_TICKS value. Expected at least $expectedPreTickFloor, got $preTicks. stdout: $gdbOutput stderr: $gdbError"
}

if ($null -eq $postTicks -or $postTicks -lt $expectedPostTickFloor) {
    throw "Unexpected POST_TICKS value. Expected at least $expectedPostTickFloor, got $postTicks. stdout: $gdbOutput stderr: $gdbError"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_COMMAND_RESULT_COUNTERS_PROBE=pass"
$gdbOutput.TrimEnd()
