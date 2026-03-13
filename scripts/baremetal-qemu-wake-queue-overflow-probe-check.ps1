param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 45,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$schedulerResetOpcode = 26
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$wakeQueueClearOpcode = 44
$schedulerWakeTaskOpcode = 45
$taskWaitOpcode = 50

$taskBudget = 5
$expectedTaskPriority = 0
$wakeQueueCapacity = 64
$overflowCycles = 66
$expectedOverflow = 2

$resultOk = 0
$modeRunning = 1
$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonManual = 3

$statusModeOffset = 6
$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34
$statusTickBatchHintOffset = 36

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$schedulerTaskCountOffset = 1
$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4

$wakeEventStride = 32
$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventReasonOffset = 12
$wakeEventTickOffset = 16

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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-wake-queue-overflow-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-wake-queue-overflow.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-wake-queue-overflow.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-wake-queue-overflow.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-wake-queue-overflow-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-wake-queue-overflow-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-wake-queue-overflow-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-wake-queue-overflow-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-wake-queue-overflow-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-wake-queue-overflow" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for wake-queue overflow runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for wake-queue overflow PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for wake-queue overflow PVH artifact failed with exit code $LASTEXITCODE"
    }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) {
    throw "Failed to resolve symbol table from $artifact using $nm"
}

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName '_start'
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName 'baremetal_main.spinPause'
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName 'baremetal_main.status'
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName 'baremetal_main.command_mailbox'
$schedulerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_state$' -SymbolName 'baremetal_main.scheduler_state'
$schedulerTasksAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_tasks$' -SymbolName 'baremetal_main.scheduler_tasks'
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName 'baremetal_main.wake_queue'
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName 'baremetal_main.wake_queue_count'
$wakeQueueHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_head$' -SymbolName 'baremetal_main.wake_queue_head'
$wakeQueueTailAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_tail$' -SymbolName 'baremetal_main.wake_queue_tail'
$wakeQueueOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_overflow$' -SymbolName 'baremetal_main.wake_queue_overflow'
$artifactForGdb = $artifact.Replace('\', '/')

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_expected_seq = 0
set `$_task_id = 0
set `$_wake_cycles = 0
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
if `$_stage == 0
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 0
    set *(unsigned char*)(0x$statusAddress+$statusModeOffset) = $modeRunning
    set *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset) = 0
    set *(short*)(0x$statusAddress+$statusLastCommandResultOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) = 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = 1
    set `$_stage = 1
  end
  continue
end
if `$_stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 2
  end
  continue
end
if `$_stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 3
  end
  continue
end
if `$_stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $expectedTaskPriority
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 4
  end
  continue
end
if `$_stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$_task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 6
  end
  continue
end
if `$_stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady
    set `$_wake_cycles = (`$_wake_cycles + 1)
    if `$_wake_cycles == $overflowCycles && *(unsigned int*)0x$wakeQueueCountAddress == $wakeQueueCapacity && *(unsigned int*)0x$wakeQueueOverflowAddress == $expectedOverflow
      set `$_oldest_index = *(unsigned int*)0x$wakeQueueTailAddress
      set `$_newest_index = (*(unsigned int*)0x$wakeQueueHeadAddress + $wakeQueueCapacity - 1) % $wakeQueueCapacity
      printf "AFTER_WAKE_QUEUE_OVERFLOW\n"
      printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
      printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
      printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
      printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
      printf "TASK_ID=%u\n", `$_task_id
      printf "TASK_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
      printf "WAKE_CYCLES=%u\n", `$_wake_cycles
      printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)0x$wakeQueueCountAddress
      printf "WAKE_QUEUE_HEAD=%u\n", *(unsigned int*)0x$wakeQueueHeadAddress
      printf "WAKE_QUEUE_TAIL=%u\n", *(unsigned int*)0x$wakeQueueTailAddress
      printf "WAKE_QUEUE_OVERFLOW=%u\n", *(unsigned int*)0x$wakeQueueOverflowAddress
      printf "OLDEST_INDEX=%u\n", `$_oldest_index
      printf "NEWEST_INDEX=%u\n", `$_newest_index
      printf "OLDEST_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (`$_oldest_index * $wakeEventStride) + $wakeEventSeqOffset)
      printf "OLDEST_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (`$_oldest_index * $wakeEventStride) + $wakeEventTaskIdOffset)
      printf "OLDEST_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress + (`$_oldest_index * $wakeEventStride) + $wakeEventReasonOffset)
      printf "OLDEST_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress + (`$_oldest_index * $wakeEventStride) + $wakeEventTickOffset)
      printf "NEWEST_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (`$_newest_index * $wakeEventStride) + $wakeEventSeqOffset)
      printf "NEWEST_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (`$_newest_index * $wakeEventStride) + $wakeEventTaskIdOffset)
      printf "NEWEST_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress + (`$_newest_index * $wakeEventStride) + $wakeEventReasonOffset)
      printf "NEWEST_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress + (`$_newest_index * $wakeEventStride) + $wakeEventTickOffset)
      quit
    else
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
      set `$_expected_seq = (`$_expected_seq + 1)
      set `$_stage = 5
    end
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

$qemuProc = $null
$gdbProc = $null
$timedOut = $false

try {
    $qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
    Start-Sleep -Milliseconds 700

    $gdbArgs = @(
        "-q",
        "-batch",
        "-x", $gdbScript
    )

    $gdbProc = Start-Process -FilePath $gdb -ArgumentList $gdbArgs -PassThru -NoNewWindow -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr
    $null = Wait-Process -Id $gdbProc.Id -Timeout $TimeoutSeconds -ErrorAction Stop
}
catch {
    $timedOut = $true
    if ($null -ne $gdbProc) {
        try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}
finally {
    if ($null -ne $qemuProc) {
        try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

$gdbOutput = ""
$gdbError = ""
$hitStart = $false
$hitAfter = $false
if (Test-Path $gdbStdout) {
    $gdbOutput = [string](Get-Content -Path $gdbStdout -Raw)
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfter = $gdbOutput.Contains("AFTER_WAKE_QUEUE_OVERFLOW")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU wake-queue overflow probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "Wake-queue overflow probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskId = Extract-IntValue -Text $gdbOutput -Name "TASK_ID"
$taskState = Extract-IntValue -Text $gdbOutput -Name "TASK_STATE"
$wakeCycles = Extract-IntValue -Text $gdbOutput -Name "WAKE_CYCLES"
$wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
$wakeQueueHead = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_HEAD"
$wakeQueueTail = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_TAIL"
$wakeQueueOverflow = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_OVERFLOW"
$oldestSeq = Extract-IntValue -Text $gdbOutput -Name "OLDEST_SEQ"
$oldestTaskId = Extract-IntValue -Text $gdbOutput -Name "OLDEST_TASK_ID"
$oldestReason = Extract-IntValue -Text $gdbOutput -Name "OLDEST_REASON"
$oldestTick = Extract-IntValue -Text $gdbOutput -Name "OLDEST_TICK"
$newestSeq = Extract-IntValue -Text $gdbOutput -Name "NEWEST_SEQ"
$newestTaskId = Extract-IntValue -Text $gdbOutput -Name "NEWEST_TASK_ID"
$newestReason = Extract-IntValue -Text $gdbOutput -Name "NEWEST_REASON"
$newestTick = Extract-IntValue -Text $gdbOutput -Name "NEWEST_TICK"

$expectedAck = 4 + ($overflowCycles * 2)
if ($ack -ne $expectedAck) { throw "Expected ACK=$expectedAck, got $ack" }
if ($lastOpcode -ne $schedulerWakeTaskOpcode) { throw "Expected LAST_OPCODE=$schedulerWakeTaskOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($ticks -lt $expectedAck) { throw "Expected TICKS >= $expectedAck, got $ticks" }
if ($taskId -le 0) { throw "Expected TASK_ID > 0, got $taskId" }
if ($taskState -ne $taskStateReady) { throw "Expected TASK_STATE=$taskStateReady, got $taskState" }
if ($wakeCycles -ne $overflowCycles) { throw "Expected WAKE_CYCLES=$overflowCycles, got $wakeCycles" }
if ($wakeQueueCount -ne $wakeQueueCapacity) { throw "Expected WAKE_QUEUE_COUNT=$wakeQueueCapacity, got $wakeQueueCount" }
if ($wakeQueueHead -ne $expectedOverflow) { throw "Expected WAKE_QUEUE_HEAD=$expectedOverflow, got $wakeQueueHead" }
if ($wakeQueueTail -ne $expectedOverflow) { throw "Expected WAKE_QUEUE_TAIL=$expectedOverflow, got $wakeQueueTail" }
if ($wakeQueueOverflow -ne $expectedOverflow) { throw "Expected WAKE_QUEUE_OVERFLOW=$expectedOverflow, got $wakeQueueOverflow" }
if ($oldestSeq -ne ($expectedOverflow + 1)) { throw "Expected OLDEST_SEQ=$($expectedOverflow + 1), got $oldestSeq" }
if ($newestSeq -ne $overflowCycles) { throw "Expected NEWEST_SEQ=$overflowCycles, got $newestSeq" }
if ($oldestTaskId -ne $taskId) { throw "Expected OLDEST_TASK_ID=$taskId, got $oldestTaskId" }
if ($newestTaskId -ne $taskId) { throw "Expected NEWEST_TASK_ID=$taskId, got $newestTaskId" }
if ($oldestReason -ne $wakeReasonManual) { throw "Expected OLDEST_REASON=$wakeReasonManual, got $oldestReason" }
if ($newestReason -ne $wakeReasonManual) { throw "Expected NEWEST_REASON=$wakeReasonManual, got $newestReason" }
if ($oldestTick -le 0) { throw "Expected OLDEST_TICK > 0, got $oldestTick" }
if ($newestTick -le $oldestTick) { throw "Expected NEWEST_TICK > OLDEST_TICK, got oldest=$oldestTick newest=$newestTick" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_ACK=$ack"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_TASK_ID=$taskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_TASK_STATE=$taskState"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_WAKE_CYCLES=$wakeCycles"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_HEAD=$wakeQueueHead"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_TAIL=$wakeQueueTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_OVERFLOW=$wakeQueueOverflow"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_OLDEST_SEQ=$oldestSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_OLDEST_TASK_ID=$oldestTaskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_OLDEST_REASON=$oldestReason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_OLDEST_TICK=$oldestTick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_NEWEST_SEQ=$newestSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_NEWEST_TASK_ID=$newestTaskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_NEWEST_REASON=$newestReason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_NEWEST_TICK=$newestTick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_OVERFLOW_PROBE=pass"

