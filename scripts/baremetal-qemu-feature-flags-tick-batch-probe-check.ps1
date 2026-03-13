param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$setFeatureFlagsOpcode = 2
$setTickBatchHintOpcode = 6
$featureFlagsValue = 2774181210 # 0xA55AA55A
$validTickBatchHint = 4
$invalidTickBatchHint = 0
$modeRunning = 1

$statusModeOffset = 6
$statusTicksOffset = 8
$statusLastHealthCodeOffset = 16
$statusFeatureFlagsOffset = 20
$statusPanicCountOffset = 24
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34
$statusTickBatchHintOffset = 36

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

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
    foreach ($name in @("qemu-system-x86_64", "qemu-system-x86_64.exe", "C:\Program Files\qemu\qemu-system-x86_64.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

function Resolve-GdbExecutable {
    foreach ($name in @("gdb", "gdb.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
    }
    return $null
}

function Resolve-NmExecutable {
    foreach ($name in @("llvm-nm", "llvm-nm.exe", "nm", "nm.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\llvm-nm.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

function Resolve-ClangExecutable {
    foreach ($name in @("clang", "clang.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\clang.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

function Resolve-LldExecutable {
    foreach ($name in @("lld", "lld.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\lld.exe")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
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

function Resolve-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
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
$zigLocalCacheDir = Join-Path $repo ".zig-cache"

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-feature-flags-tick-batch-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-feature-flags-tick-batch.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-feature-flags-tick-batch.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-feature-flags-tick-batch.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-feature-flags-tick-batch-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-feature-flags-tick-batch-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-feature-flags-tick-batch-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-feature-flags-tick-batch-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-feature-flags-tick-batch-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-feature-flags-tick-batch" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for feature-flags/tick-batch runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for feature-flags/tick-batch PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for feature-flags/tick-batch PVH artifact failed with exit code $LASTEXITCODE"
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
$artifactForGdb = $artifact.Replace('\', '/')

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
continue
end
break *0x$spinPauseAddress
commands
silent
if `$stage == 0
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 0
    set *(unsigned char*)(0x$statusAddress+$statusModeOffset) = $modeRunning
    set *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastHealthCodeOffset) = 200
    set *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusPanicCountOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset) = 0
    set *(short*)(0x$statusAddress+$statusLastCommandResultOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) = 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setFeatureFlagsOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $featureFlagsValue
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 1
  end
  continue
end
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset) == $featureFlagsValue && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == 1 && *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) == 1
    printf "AFTER_STAGE1_FEATURE_FLAGS\n"
    printf "STAGE1_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "STAGE1_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "STAGE1_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "STAGE1_TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "STAGE1_FEATURE_FLAGS=%u\n", *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset)
    printf "STAGE1_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $validTickBatchHint
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == $validTickBatchHint && *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) == 5
    printf "AFTER_STAGE2_TICK_BATCH_VALID\n"
    printf "STAGE2_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "STAGE2_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "STAGE2_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "STAGE2_TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "STAGE2_FEATURE_FLAGS=%u\n", *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset)
    printf "STAGE2_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $invalidTickBatchHint
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == -22 && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == $validTickBatchHint && *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) == 9
    printf "AFTER_STAGE3_TICK_BATCH_INVALID\n"
    printf "STAGE3_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "STAGE3_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "STAGE3_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "STAGE3_TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "STAGE3_FEATURE_FLAGS=%u\n", *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset)
    printf "STAGE3_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "AFTER_FEATURE_FLAGS_TICK_BATCH\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "FEATURE_FLAGS=%u\n", *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset)
    printf "TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
    printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    quit
  end
  continue
end
continue
end
continue
"@ | Set-Content -Path $gdbScript -Encoding Ascii

$qemuArgs = @("-kernel", $artifact, "-nographic", "-no-reboot", "-no-shutdown", "-serial", "none", "-monitor", "none", "-S", "-gdb", "tcp::$GdbPort")
$qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
Start-Sleep -Milliseconds 700
$gdbProc = Start-Process -FilePath $gdb -ArgumentList @("-q", "-batch", "-x", $gdbScript) -PassThru -NoNewWindow -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr

$timedOut = $false
try {
    if (-not $gdbProc.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
        throw "GDB timed out after $TimeoutSeconds seconds"
    }
    $gdbProc.Refresh()
    $gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int]$gdbProc.ExitCode }
    if ($gdbExitCode -ne 0) {
        $stderr = if (Test-Path $gdbStderr) { Get-Content -Raw $gdbStderr } else { "" }
        $stdout = if (Test-Path $gdbStdout) { Get-Content -Raw $gdbStdout } else { "" }
        throw "GDB exited with code $gdbExitCode`nSTDOUT:`n$stdout`nSTDERR:`n$stderr"
    }
}
finally {
    if ($null -ne $gdbProc -and -not $gdbProc.HasExited) {
        try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($null -ne $qemuProc -and -not $qemuProc.HasExited) {
        try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

$stdout = if (Test-Path $gdbStdout) { Get-Content -Raw $gdbStdout } else { "" }
$stderr = if (Test-Path $gdbStderr) { Get-Content -Raw $gdbStderr } else { "" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_QEMU_STDERR=$qemuStderr"

if ($stdout -notmatch 'HIT_START' -or $stdout -notmatch 'AFTER_STAGE1_FEATURE_FLAGS' -or $stdout -notmatch 'AFTER_STAGE2_TICK_BATCH_VALID' -or $stdout -notmatch 'AFTER_STAGE3_TICK_BATCH_INVALID' -or $stdout -notmatch 'AFTER_FEATURE_FLAGS_TICK_BATCH') {
    Write-Output $stdout
    if ($stderr) { Write-Output $stderr }
    throw "Feature flags / tick batch probe did not reach the expected GDB checkpoints"
}

$expectedInts = @{
    "ACK" = 3
    "LAST_OPCODE" = $setTickBatchHintOpcode
    "LAST_RESULT" = -22
    "FEATURE_FLAGS" = $featureFlagsValue
    "TICK_BATCH_HINT" = $validTickBatchHint
    "MAILBOX_OPCODE" = $setTickBatchHintOpcode
    "MAILBOX_SEQ" = 3
    "TICKS" = 9
}

foreach ($entry in $expectedInts.GetEnumerator()) {
    $actual = Extract-IntValue -Text $stdout -Name $entry.Key
    if ($null -eq $actual) {
        throw "Missing expected output line for $($entry.Key)"
    }
    if ($actual -ne $entry.Value) {
        throw "Unexpected value for $($entry.Key): expected $($entry.Value), got $actual"
    }
    Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_$($entry.Key)=$actual"
}

Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_PROBE=pass"

$stageExpectedInts = @(
    @{ Prefix = "STAGE1"; Name = "ACK"; Expected = 1 },
    @{ Prefix = "STAGE1"; Name = "LAST_OPCODE"; Expected = $setFeatureFlagsOpcode },
    @{ Prefix = "STAGE1"; Name = "LAST_RESULT"; Expected = 0 },
    @{ Prefix = "STAGE1"; Name = "TICKS"; Expected = 1 },
    @{ Prefix = "STAGE1"; Name = "FEATURE_FLAGS"; Expected = $featureFlagsValue },
    @{ Prefix = "STAGE1"; Name = "TICK_BATCH_HINT"; Expected = 1 },
    @{ Prefix = "STAGE2"; Name = "ACK"; Expected = 2 },
    @{ Prefix = "STAGE2"; Name = "LAST_OPCODE"; Expected = $setTickBatchHintOpcode },
    @{ Prefix = "STAGE2"; Name = "LAST_RESULT"; Expected = 0 },
    @{ Prefix = "STAGE2"; Name = "TICKS"; Expected = 5 },
    @{ Prefix = "STAGE2"; Name = "FEATURE_FLAGS"; Expected = $featureFlagsValue },
    @{ Prefix = "STAGE2"; Name = "TICK_BATCH_HINT"; Expected = $validTickBatchHint },
    @{ Prefix = "STAGE3"; Name = "ACK"; Expected = 3 },
    @{ Prefix = "STAGE3"; Name = "LAST_OPCODE"; Expected = $setTickBatchHintOpcode },
    @{ Prefix = "STAGE3"; Name = "LAST_RESULT"; Expected = -22 },
    @{ Prefix = "STAGE3"; Name = "TICKS"; Expected = 9 },
    @{ Prefix = "STAGE3"; Name = "FEATURE_FLAGS"; Expected = $featureFlagsValue },
    @{ Prefix = "STAGE3"; Name = "TICK_BATCH_HINT"; Expected = $validTickBatchHint }
)

foreach ($entry in $stageExpectedInts) {
    $label = "$($entry.Prefix)_$($entry.Name)"
    $actual = Extract-IntValue -Text $stdout -Name $label
    if ($null -eq $actual) {
        throw "Missing expected stage output line for $label"
    }
    if ($actual -ne $entry.Expected) {
        throw "Unexpected value for ${label}: expected $($entry.Expected), got $actual"
    }
    Write-Output "BAREMETAL_QEMU_FEATURE_FLAGS_TICK_BATCH_${label}=$actual"
}

