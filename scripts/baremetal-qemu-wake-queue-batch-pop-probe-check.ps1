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
$wakeQueuePopOpcode = 54

$taskBudget = 5
$expectedTaskPriority = 0
$wakeQueueCapacity = 64
$overflowCycles = 66
$expectedOverflow = 2
$batchPopCount = 62

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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-wake-queue-batch-pop-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-wake-queue-batch-pop.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-wake-queue-batch-pop.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-wake-queue-batch-pop.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-wake-queue-batch-pop-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-wake-queue-batch-pop-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-wake-queue-batch-pop-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-wake-queue-batch-pop-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-wake-queue-batch-pop-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-wake-queue-batch-pop" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for Wake-queue batch-pop runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for Wake-queue batch-pop PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for Wake-queue batch-pop PVH artifact failed with exit code $LASTEXITCODE"
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
set `$_after_batch_count = 0
set `$_after_batch_head = 0
set `$_after_batch_tail = 0
set `$_after_batch_overflow = 0
set `$_after_batch_first_seq = 0
set `$_after_batch_second_seq = 0
set `$_after_single_count = 0
set `$_after_single_tail = 0
set `$_after_single_seq = 0
set `$_after_drain_count = 0
set `$_after_drain_head = 0
set `$_after_drain_tail = 0
set `$_after_drain_overflow = 0
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
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $batchPopCount
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
      set `$_expected_seq = (`$_expected_seq + 1)
      set `$_stage = 7
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
if `$_stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 2 && *(unsigned int*)0x$wakeQueueHeadAddress == 2 && *(unsigned int*)0x$wakeQueueTailAddress == 0
    set `$_after_batch_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_after_batch_head = *(unsigned int*)0x$wakeQueueHeadAddress
    set `$_after_batch_tail = *(unsigned int*)0x$wakeQueueTailAddress
    set `$_after_batch_overflow = *(unsigned int*)0x$wakeQueueOverflowAddress
    set `$_after_batch_first_seq = *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventSeqOffset)
    set `$_after_batch_second_seq = *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventSeqOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 8
  end
  continue
end
if `$_stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 1 && *(unsigned int*)0x$wakeQueueTailAddress == 1
    set `$_after_single_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_after_single_tail = *(unsigned int*)0x$wakeQueueTailAddress
    set `$_after_single_seq = *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventSeqOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 9
  end
  continue
end
if `$_stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 0 && *(unsigned int*)0x$wakeQueueHeadAddress == 2 && *(unsigned int*)0x$wakeQueueTailAddress == 2
    set `$_after_drain_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_after_drain_head = *(unsigned int*)0x$wakeQueueHeadAddress
    set `$_after_drain_tail = *(unsigned int*)0x$wakeQueueTailAddress
    set `$_after_drain_overflow = *(unsigned int*)0x$wakeQueueOverflowAddress
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 10
  end
  continue
end
if `$_stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 11
  end
  continue
end
if `$_stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 1 && *(unsigned int*)0x$wakeQueueHeadAddress == 3 && *(unsigned int*)0x$wakeQueueTailAddress == 2 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady
    printf "AFTER_WAKE_QUEUE_BATCH_POP\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "TASK_ID=%u\n", `$_task_id
    printf "TASK_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    printf "WAKE_CYCLES=%u\n", `$_wake_cycles
    printf "AFTER_BATCH_COUNT=%u\n", `$_after_batch_count
    printf "AFTER_BATCH_HEAD=%u\n", `$_after_batch_head
    printf "AFTER_BATCH_TAIL=%u\n", `$_after_batch_tail
    printf "AFTER_BATCH_OVERFLOW=%u\n", `$_after_batch_overflow
    printf "AFTER_BATCH_FIRST_SEQ=%u\n", `$_after_batch_first_seq
    printf "AFTER_BATCH_SECOND_SEQ=%u\n", `$_after_batch_second_seq
    printf "AFTER_SINGLE_COUNT=%u\n", `$_after_single_count
    printf "AFTER_SINGLE_TAIL=%u\n", `$_after_single_tail
    printf "AFTER_SINGLE_SEQ=%u\n", `$_after_single_seq
    printf "AFTER_DRAIN_COUNT=%u\n", `$_after_drain_count
    printf "AFTER_DRAIN_HEAD=%u\n", `$_after_drain_head
    printf "AFTER_DRAIN_TAIL=%u\n", `$_after_drain_tail
    printf "AFTER_DRAIN_OVERFLOW=%u\n", `$_after_drain_overflow
    printf "REFILL_COUNT=%u\n", *(unsigned int*)0x$wakeQueueCountAddress
    printf "REFILL_HEAD=%u\n", *(unsigned int*)0x$wakeQueueHeadAddress
    printf "REFILL_TAIL=%u\n", *(unsigned int*)0x$wakeQueueTailAddress
    printf "REFILL_OVERFLOW=%u\n", *(unsigned int*)0x$wakeQueueOverflowAddress
    printf "REFILL_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventSeqOffset)
    printf "REFILL_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventTaskIdOffset)
    printf "REFILL_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventReasonOffset)
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
    $hitAfter = $gdbOutput.Contains("AFTER_WAKE_QUEUE_BATCH_POP")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU Wake-queue batch-pop probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "Wake-queue batch-pop probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskId = Extract-IntValue -Text $gdbOutput -Name "TASK_ID"
$taskState = Extract-IntValue -Text $gdbOutput -Name "TASK_STATE"
$wakeCycles = Extract-IntValue -Text $gdbOutput -Name "WAKE_CYCLES"
$afterBatchCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_BATCH_COUNT"
$afterBatchHead = Extract-IntValue -Text $gdbOutput -Name "AFTER_BATCH_HEAD"
$afterBatchTail = Extract-IntValue -Text $gdbOutput -Name "AFTER_BATCH_TAIL"
$afterBatchOverflow = Extract-IntValue -Text $gdbOutput -Name "AFTER_BATCH_OVERFLOW"
$afterBatchFirstSeq = Extract-IntValue -Text $gdbOutput -Name "AFTER_BATCH_FIRST_SEQ"
$afterBatchSecondSeq = Extract-IntValue -Text $gdbOutput -Name "AFTER_BATCH_SECOND_SEQ"
$afterSingleCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_SINGLE_COUNT"
$afterSingleTail = Extract-IntValue -Text $gdbOutput -Name "AFTER_SINGLE_TAIL"
$afterSingleSeq = Extract-IntValue -Text $gdbOutput -Name "AFTER_SINGLE_SEQ"
$afterDrainCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_DRAIN_COUNT"
$afterDrainHead = Extract-IntValue -Text $gdbOutput -Name "AFTER_DRAIN_HEAD"
$afterDrainTail = Extract-IntValue -Text $gdbOutput -Name "AFTER_DRAIN_TAIL"
$afterDrainOverflow = Extract-IntValue -Text $gdbOutput -Name "AFTER_DRAIN_OVERFLOW"
$refillCount = Extract-IntValue -Text $gdbOutput -Name "REFILL_COUNT"
$refillHead = Extract-IntValue -Text $gdbOutput -Name "REFILL_HEAD"
$refillTail = Extract-IntValue -Text $gdbOutput -Name "REFILL_TAIL"
$refillOverflow = Extract-IntValue -Text $gdbOutput -Name "REFILL_OVERFLOW"
$refillSeq = Extract-IntValue -Text $gdbOutput -Name "REFILL_SEQ"
$refillTaskId = Extract-IntValue -Text $gdbOutput -Name "REFILL_TASK_ID"
$refillReason = Extract-IntValue -Text $gdbOutput -Name "REFILL_REASON"

$expectedAck = 4 + ($overflowCycles * 2) + 5
if ($ack -ne $expectedAck) { throw "Expected ACK=$expectedAck, got $ack" }
if ($lastOpcode -ne $schedulerWakeTaskOpcode) { throw "Expected LAST_OPCODE=$schedulerWakeTaskOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($ticks -lt $expectedAck) { throw "Expected TICKS >= $expectedAck, got $ticks" }
if ($taskId -le 0) { throw "Expected TASK_ID > 0, got $taskId" }
if ($taskState -ne $taskStateReady) { throw "Expected TASK_STATE=$taskStateReady, got $taskState" }
if ($wakeCycles -ne $overflowCycles) { throw "Expected WAKE_CYCLES=$overflowCycles, got $wakeCycles" }
if ($afterBatchCount -ne 2) { throw "Expected AFTER_BATCH_COUNT=2, got $afterBatchCount" }
if ($afterBatchHead -ne 2) { throw "Expected AFTER_BATCH_HEAD=2, got $afterBatchHead" }
if ($afterBatchTail -ne 0) { throw "Expected AFTER_BATCH_TAIL=0, got $afterBatchTail" }
if ($afterBatchOverflow -ne $expectedOverflow) { throw "Expected AFTER_BATCH_OVERFLOW=$expectedOverflow, got $afterBatchOverflow" }
if ($afterBatchFirstSeq -ne 65) { throw "Expected AFTER_BATCH_FIRST_SEQ=65, got $afterBatchFirstSeq" }
if ($afterBatchSecondSeq -ne 66) { throw "Expected AFTER_BATCH_SECOND_SEQ=66, got $afterBatchSecondSeq" }
if ($afterSingleCount -ne 1) { throw "Expected AFTER_SINGLE_COUNT=1, got $afterSingleCount" }
if ($afterSingleTail -ne 1) { throw "Expected AFTER_SINGLE_TAIL=1, got $afterSingleTail" }
if ($afterSingleSeq -ne 66) { throw "Expected AFTER_SINGLE_SEQ=66, got $afterSingleSeq" }
if ($afterDrainCount -ne 0) { throw "Expected AFTER_DRAIN_COUNT=0, got $afterDrainCount" }
if ($afterDrainHead -ne 2) { throw "Expected AFTER_DRAIN_HEAD=2, got $afterDrainHead" }
if ($afterDrainTail -ne 2) { throw "Expected AFTER_DRAIN_TAIL=2, got $afterDrainTail" }
if ($afterDrainOverflow -ne $expectedOverflow) { throw "Expected AFTER_DRAIN_OVERFLOW=$expectedOverflow, got $afterDrainOverflow" }
if ($refillCount -ne 1) { throw "Expected REFILL_COUNT=1, got $refillCount" }
if ($refillHead -ne 3) { throw "Expected REFILL_HEAD=3, got $refillHead" }
if ($refillTail -ne 2) { throw "Expected REFILL_TAIL=2, got $refillTail" }
if ($refillOverflow -ne $expectedOverflow) { throw "Expected REFILL_OVERFLOW=$expectedOverflow, got $refillOverflow" }
if ($refillSeq -ne 67) { throw "Expected REFILL_SEQ=67, got $refillSeq" }
if ($refillTaskId -ne $taskId) { throw "Expected REFILL_TASK_ID=$taskId, got $refillTaskId" }
if ($refillReason -ne $wakeReasonManual) { throw "Expected REFILL_REASON=$wakeReasonManual, got $refillReason" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_ACK=$ack"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_TASK_ID=$taskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_TASK_STATE=$taskState"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_WAKE_CYCLES=$wakeCycles"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_BATCH_COUNT=$afterBatchCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_BATCH_HEAD=$afterBatchHead"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_BATCH_TAIL=$afterBatchTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_BATCH_OVERFLOW=$afterBatchOverflow"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_BATCH_FIRST_SEQ=$afterBatchFirstSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_BATCH_SECOND_SEQ=$afterBatchSecondSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_SINGLE_COUNT=$afterSingleCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_SINGLE_TAIL=$afterSingleTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_SINGLE_SEQ=$afterSingleSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_DRAIN_COUNT=$afterDrainCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_DRAIN_HEAD=$afterDrainHead"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_DRAIN_TAIL=$afterDrainTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_AFTER_DRAIN_OVERFLOW=$afterDrainOverflow"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_REFILL_COUNT=$refillCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_REFILL_HEAD=$refillHead"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_REFILL_TAIL=$refillTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_REFILL_OVERFLOW=$refillOverflow"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_REFILL_SEQ=$refillSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_REFILL_TASK_ID=$refillTaskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_REFILL_REASON=$refillReason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_BATCH_POP_PROBE=pass"


