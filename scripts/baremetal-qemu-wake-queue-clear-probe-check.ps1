param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90,
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

$timerPendingWakeCountOffset = 2

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
    if ($env:ZIG_GLOBAL_CACHE_DIR -and $env:ZIG_GLOBAL_CACHE_DIR.Trim().Length -gt 0) { $candidates += $env:ZIG_GLOBAL_CACHE_DIR }
    if ($env:LOCALAPPDATA -and $env:LOCALAPPDATA.Trim().Length -gt 0) { $candidates += (Join-Path $env:LOCALAPPDATA "zig") }
    if ($env:XDG_CACHE_HOME -and $env:XDG_CACHE_HOME.Trim().Length -gt 0) { $candidates += (Join-Path $env:XDG_CACHE_HOME "zig") }
    if ($env:HOME -and $env:HOME.Trim().Length -gt 0) { $candidates += (Join-Path $env:HOME ".cache/zig") }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }
    return (Join-Path $repo ".zig-global-cache")
}

function Resolve-CompilerRtArchive {
    $cacheRoot = Resolve-ZigGlobalCacheDir
    $localZigObjRoot = Join-Path $cacheRoot "o"
    if (-not (Test-Path $localZigObjRoot)) { return $null }
    $candidate = Get-ChildItem -Path $localZigObjRoot -Recurse -Filter "libcompiler_rt.a" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -ne $candidate) { return $candidate.FullName }
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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-wake-queue-clear-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-wake-queue-clear.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-wake-queue-clear.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-wake-queue-clear.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-wake-queue-clear-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-wake-queue-clear-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-wake-queue-clear-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-wake-queue-clear-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-wake-queue-clear-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-wake-queue-clear" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for wake-queue clear runtime failed with exit code $LASTEXITCODE" }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for wake-queue clear PVH shim failed with exit code $LASTEXITCODE" }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for wake-queue clear PVH artifact failed with exit code $LASTEXITCODE" }
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
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName 'baremetal_main.timer_state'
$artifactForGdb = $artifact.Replace('\', '/')

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_expected_seq = 0
set `$_task_id = 0
set `$_wake_cycles = 0
set `$_pre_oldest_index = 0
set `$_pre_newest_index = 0
set `$_pre_head = 0
set `$_pre_tail = 0
set `$_pre_overflow = 0
set `$_pre_oldest_seq = 0
set `$_pre_newest_seq = 0
set `$_post_clear_count = 0
set `$_post_clear_head = 0
set `$_post_clear_tail = 0
set `$_post_clear_overflow = 0
set `$_post_clear_pending_wake_count = 0
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
      set `$_pre_head = *(unsigned int*)0x$wakeQueueHeadAddress
      set `$_pre_tail = *(unsigned int*)0x$wakeQueueTailAddress
      set `$_pre_overflow = *(unsigned int*)0x$wakeQueueOverflowAddress
      set `$_pre_oldest_index = *(unsigned int*)0x$wakeQueueTailAddress
      set `$_pre_newest_index = (*(unsigned int*)0x$wakeQueueHeadAddress + $wakeQueueCapacity - 1) % $wakeQueueCapacity
      set `$_pre_oldest_seq = *(unsigned int*)(0x$wakeQueueAddress + (`$_pre_oldest_index * $wakeEventStride) + $wakeEventSeqOffset)
      set `$_pre_newest_seq = *(unsigned int*)(0x$wakeQueueAddress + (`$_pre_newest_index * $wakeEventStride) + $wakeEventSeqOffset)
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
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
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 0 && *(unsigned int*)0x$wakeQueueHeadAddress == 0 && *(unsigned int*)0x$wakeQueueTailAddress == 0 && *(unsigned int*)0x$wakeQueueOverflowAddress == 0 && *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset) == 0
    set `$_post_clear_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_post_clear_head = *(unsigned int*)0x$wakeQueueHeadAddress
    set `$_post_clear_tail = *(unsigned int*)0x$wakeQueueTailAddress
    set `$_post_clear_overflow = *(unsigned int*)0x$wakeQueueOverflowAddress
    set `$_post_clear_pending_wake_count = *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 8
  end
  continue
end
if `$_stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 9
  end
  continue
end
if `$_stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 1 && *(unsigned int*)0x$wakeQueueHeadAddress == 1 && *(unsigned int*)0x$wakeQueueTailAddress == 0 && *(unsigned int*)0x$wakeQueueOverflowAddress == 0 && *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset) == 1
    printf "HIT_AFTER_WAKE_QUEUE_CLEAR_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "TASK_ID=%u\n", `$_task_id
    printf "PRE_COUNT=%u\n", $wakeQueueCapacity
    printf "PRE_HEAD=%u\n", `$_pre_head
    printf "PRE_TAIL=%u\n", `$_pre_tail
    printf "PRE_OVERFLOW=%u\n", `$_pre_overflow
    printf "PRE_OLDEST_SEQ=%u\n", `$_pre_oldest_seq
    printf "PRE_NEWEST_SEQ=%u\n", `$_pre_newest_seq
    printf "POST_CLEAR_COUNT=%u\n", `$_post_clear_count
    printf "POST_CLEAR_HEAD=%u\n", `$_post_clear_head
    printf "POST_CLEAR_TAIL=%u\n", `$_post_clear_tail
    printf "POST_CLEAR_OVERFLOW=%u\n", `$_post_clear_overflow
    printf "POST_CLEAR_PENDING_WAKE_COUNT=%u\n", `$_post_clear_pending_wake_count
    printf "POST_REUSE_COUNT=%u\n", *(unsigned int*)0x$wakeQueueCountAddress
    printf "POST_REUSE_HEAD=%u\n", *(unsigned int*)0x$wakeQueueHeadAddress
    printf "POST_REUSE_TAIL=%u\n", *(unsigned int*)0x$wakeQueueTailAddress
    printf "POST_REUSE_OVERFLOW=%u\n", *(unsigned int*)0x$wakeQueueOverflowAddress
    printf "POST_REUSE_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    printf "POST_REUSE_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventSeqOffset)
    printf "POST_REUSE_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTaskIdOffset)
    printf "POST_REUSE_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventReasonOffset)
    printf "POST_REUSE_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTickOffset)
    detach
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

$gdbText = ""
$gdbError = ""
$hitStart = $false
$hitAfter = $false
if (Test-Path $gdbStdout) {
    $gdbText = [string](Get-Content -Path $gdbStdout -Raw)
    $hitStart = $gdbText.Contains("HIT_START")
    $hitAfter = $gdbText.Contains("HIT_AFTER_WAKE_QUEUE_CLEAR_PROBE")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU wake-queue clear probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbText`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbText`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "Wake-queue clear probe did not reach expected checkpoints.`nSTDOUT:`n$gdbText`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbText -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbText -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbText -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbText -Name "TICKS"
$taskId = Extract-IntValue -Text $gdbText -Name "TASK_ID"
$preCount = Extract-IntValue -Text $gdbText -Name "PRE_COUNT"
$preHead = Extract-IntValue -Text $gdbText -Name "PRE_HEAD"
$preTail = Extract-IntValue -Text $gdbText -Name "PRE_TAIL"
$preOverflow = Extract-IntValue -Text $gdbText -Name "PRE_OVERFLOW"
$preOldestSeq = Extract-IntValue -Text $gdbText -Name "PRE_OLDEST_SEQ"
$preNewestSeq = Extract-IntValue -Text $gdbText -Name "PRE_NEWEST_SEQ"
$postClearCount = Extract-IntValue -Text $gdbText -Name "POST_CLEAR_COUNT"
$postClearHead = Extract-IntValue -Text $gdbText -Name "POST_CLEAR_HEAD"
$postClearTail = Extract-IntValue -Text $gdbText -Name "POST_CLEAR_TAIL"
$postClearOverflow = Extract-IntValue -Text $gdbText -Name "POST_CLEAR_OVERFLOW"
$postClearPendingWakeCount = Extract-IntValue -Text $gdbText -Name "POST_CLEAR_PENDING_WAKE_COUNT"
$postReuseCount = Extract-IntValue -Text $gdbText -Name "POST_REUSE_COUNT"
$postReuseHead = Extract-IntValue -Text $gdbText -Name "POST_REUSE_HEAD"
$postReuseTail = Extract-IntValue -Text $gdbText -Name "POST_REUSE_TAIL"
$postReuseOverflow = Extract-IntValue -Text $gdbText -Name "POST_REUSE_OVERFLOW"
$postReusePendingWakeCount = Extract-IntValue -Text $gdbText -Name "POST_REUSE_PENDING_WAKE_COUNT"
$postReuseSeq = Extract-IntValue -Text $gdbText -Name "POST_REUSE_SEQ"
$postReuseTaskId = Extract-IntValue -Text $gdbText -Name "POST_REUSE_TASK_ID"
$postReuseReason = Extract-IntValue -Text $gdbText -Name "POST_REUSE_REASON"
$postReuseTick = Extract-IntValue -Text $gdbText -Name "POST_REUSE_TICK"

if ($null -in @($ack, $lastOpcode, $lastResult, $ticks, $taskId, $preCount, $preHead, $preTail, $preOverflow,
        $preOldestSeq, $preNewestSeq, $postClearCount, $postClearHead, $postClearTail, $postClearOverflow,
        $postClearPendingWakeCount, $postReuseCount, $postReuseHead, $postReuseTail, $postReuseOverflow,
        $postReusePendingWakeCount, $postReuseSeq, $postReuseTaskId, $postReuseReason, $postReuseTick)) {
    throw "Probe output was missing one or more expected values."
}

if ($ack -ne 139) { throw "Expected final ACK 139, got $ack" }
if ($lastOpcode -ne $schedulerWakeTaskOpcode) { throw "Expected final opcode $schedulerWakeTaskOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected final result $resultOk, got $lastResult" }
if ($ticks -lt 139) { throw "Expected ticks >= 139, got $ticks" }
if ($preCount -ne $wakeQueueCapacity) { throw "Expected pre-clear count $wakeQueueCapacity, got $preCount" }
if ($preHead -ne 2) { throw "Expected pre-clear head 2, got $preHead" }
if ($preTail -ne 2) { throw "Expected pre-clear tail 2, got $preTail" }
if ($preOverflow -ne $expectedOverflow) { throw "Expected pre-clear overflow $expectedOverflow, got $preOverflow" }
if ($preOldestSeq -ne 3) { throw "Expected pre-clear oldest seq 3, got $preOldestSeq" }
if ($preNewestSeq -ne 66) { throw "Expected pre-clear newest seq 66, got $preNewestSeq" }
if ($postClearCount -ne 0) { throw "Expected post-clear count 0, got $postClearCount" }
if ($postClearHead -ne 0) { throw "Expected post-clear head 0, got $postClearHead" }
if ($postClearTail -ne 0) { throw "Expected post-clear tail 0, got $postClearTail" }
if ($postClearOverflow -ne 0) { throw "Expected post-clear overflow 0, got $postClearOverflow" }
if ($postClearPendingWakeCount -ne 0) { throw "Expected post-clear pending wake count 0, got $postClearPendingWakeCount" }
if ($postReuseCount -ne 1) { throw "Expected post-reuse count 1, got $postReuseCount" }
if ($postReuseHead -ne 1) { throw "Expected post-reuse head 1, got $postReuseHead" }
if ($postReuseTail -ne 0) { throw "Expected post-reuse tail 0, got $postReuseTail" }
if ($postReuseOverflow -ne 0) { throw "Expected post-reuse overflow 0, got $postReuseOverflow" }
if ($postReusePendingWakeCount -ne 1) { throw "Expected post-reuse pending wake count 1, got $postReusePendingWakeCount" }
if ($postReuseSeq -ne 1) { throw "Expected post-reuse seq 1, got $postReuseSeq" }
if ($postReuseTaskId -ne $taskId) { throw "Expected post-reuse task id $taskId, got $postReuseTaskId" }
if ($postReuseReason -ne $wakeReasonManual) { throw "Expected post-reuse reason $wakeReasonManual, got $postReuseReason" }
if ($postReuseTick -le 0) { throw "Expected post-reuse tick > 0, got $postReuseTick" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_ACK=$ack"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_TASK_ID=$taskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PRE_COUNT=$preCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PRE_HEAD=$preHead"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PRE_TAIL=$preTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PRE_OVERFLOW=$preOverflow"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PRE_OLDEST_SEQ=$preOldestSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PRE_NEWEST_SEQ=$preNewestSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_COUNT=$postClearCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_HEAD=$postClearHead"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_TAIL=$postClearTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_OVERFLOW=$postClearOverflow"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_CLEAR_PENDING_WAKE_COUNT=$postClearPendingWakeCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_COUNT=$postReuseCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_HEAD=$postReuseHead"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_TAIL=$postReuseTail"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_OVERFLOW=$postReuseOverflow"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_PENDING_WAKE_COUNT=$postReusePendingWakeCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_SEQ=$postReuseSeq"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_TASK_ID=$postReuseTaskId"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_REASON=$postReuseReason"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_POST_REUSE_TICK=$postReuseTick"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_CLEAR_PROBE=pass"
