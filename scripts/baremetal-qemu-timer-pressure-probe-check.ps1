param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$schedulerResetOpcode = 26
$taskCreateOpcode = 27
$schedulerDisableOpcode = 25
$timerResetOpcode = 41
$timerScheduleOpcode = 42
$timerCancelTaskOpcode = 52
$wakeQueueClearOpcode = 44

$taskCapacity = 16
$reuseSlotIndex = 5
$taskBudgetBase = 4
$taskPriorityBase = 1
$delayBase = 40
$reuseDelay = 200
$resultOk = 0
$modeRunning = 1
$taskStateWaiting = 6
$timerEntryStateArmed = 1
$timerEntryStateCanceled = 3

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

$timerEntryCountOffset = 1
$timerNextTimerIdOffset = 4
$timerDispatchCountOffset = 8
$timerEntryStride = 40
$timerEntryTimerIdOffset = 0
$timerEntryTaskIdOffset = 4
$timerEntryStateOffset = 8
$timerEntryNextFireTickOffset = 16

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
    Write-Output "BAREMETAL_QEMU_TIMER_PRESSURE_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_PRESSURE_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_PRESSURE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_TIMER_PRESSURE_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-timer-pressure-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-timer-pressure.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-timer-pressure.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-timer-pressure.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-timer-pressure-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-timer-pressure-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-timer-pressure-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-timer-pressure-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-timer-pressure-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-timer-pressure" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for timer pressure runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for timer pressure PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for timer pressure PVH artifact failed with exit code $LASTEXITCODE"
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
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName 'baremetal_main.timer_state'
$timerEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_entries$' -SymbolName 'baremetal_main.timer_entries'
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName 'baremetal_main.wake_queue_count'
$artifactForGdb = $artifact.Replace('\', '/')
$reuseTaskAddressExpr = "0x$schedulerTasksAddress+$($reuseSlotIndex * $taskStride)"
$lastTaskAddressExpr = "0x$schedulerTasksAddress+$((($taskCapacity - 1) * $taskStride))"
$reuseTimerAddressExpr = "0x$timerEntriesAddress+$($reuseSlotIndex * $timerEntryStride)"
$lastTimerAddressExpr = "0x$timerEntriesAddress+$((($taskCapacity - 1) * $timerEntryStride))"

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_create_completed = 0
set `$_schedule_completed = 0
set `$_full_task_count = 0
set `$_full_timer_count = 0
set `$_first_timer_id = 0
set `$_last_timer_id = 0
set `$_reuse_task_id = 0
set `$_reuse_old_timer_id = 0
set `$_reuse_canceled_state = 0
set `$_reuse_new_timer_id = 0
set `$_next_timer_id_after_full = 0
set `$_next_timer_id_after_reuse = 0
set `$_reuse_next_fire = 0
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
    set `$_stage = 1
  end
  continue
end
if `$_stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 2
  end
  continue
end
if `$_stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 3
  end
  continue
end
if `$_stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3 && *(unsigned int*)0x$wakeQueueCountAddress == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 4
  end
  continue
end
if `$_stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudgetBase
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriorityBase
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == (5 + `$_create_completed) && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == (`$_create_completed + 1)
    if `$_create_completed < ($taskCapacity - 1)
      set `$_create_completed = (`$_create_completed + 1)
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (5 + `$_create_completed)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = ($taskBudgetBase + `$_create_completed)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = ($taskPriorityBase + `$_create_completed)
    else
      set `$_full_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
      set `$_reuse_task_id = *(unsigned int*)($reuseTaskAddressExpr+$taskIdOffset)
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerScheduleOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 21
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $delayBase
      set `$_stage = 6
    end
  end
  continue
end
if `$_stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == (21 + `$_schedule_completed) && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == (`$_schedule_completed + 1)
    if `$_schedule_completed == 0
      set `$_first_timer_id = *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
    end
    if `$_schedule_completed < ($taskCapacity - 1)
      set `$_schedule_completed = (`$_schedule_completed + 1)
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerScheduleOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (21 + `$_schedule_completed)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = *(unsigned int*)(0x$schedulerTasksAddress+(`$_schedule_completed * $taskStride)+$taskIdOffset)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = ($delayBase + `$_schedule_completed)
    else
      set `$_full_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
      set `$_last_timer_id = *(unsigned int*)($lastTimerAddressExpr+$timerEntryTimerIdOffset)
      set `$_reuse_old_timer_id = *(unsigned int*)($reuseTimerAddressExpr+$timerEntryTimerIdOffset)
      set `$_next_timer_id_after_full = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerCancelTaskOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 37
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_reuse_task_id
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
      set `$_stage = 7
    end
  end
  continue
end
if `$_stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 37 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == ($taskCapacity - 1) && *(unsigned char*)($reuseTimerAddressExpr+$timerEntryStateOffset) == $timerEntryStateCanceled
    set `$_cancel_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_reuse_canceled_state = *(unsigned char*)($reuseTimerAddressExpr+$timerEntryStateOffset)
    set `$_cancel_next_timer_id = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set `$_cancel_task_state = *(unsigned char*)($reuseTaskAddressExpr+$taskStateOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerScheduleOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 38
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_reuse_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $reuseDelay
    set `$_stage = 8
  end
  continue
end
if `$_stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 38 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == $taskCapacity && *(unsigned char*)($reuseTimerAddressExpr+$timerEntryStateOffset) == $timerEntryStateArmed && *(unsigned int*)($reuseTimerAddressExpr+$timerEntryTimerIdOffset) != `$_reuse_old_timer_id
    set `$_reuse_new_timer_id = *(unsigned int*)($reuseTimerAddressExpr+$timerEntryTimerIdOffset)
    set `$_next_timer_id_after_reuse = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set `$_reuse_next_fire = *(unsigned long long*)($reuseTimerAddressExpr+$timerEntryNextFireTickOffset)
    set `$_stage = 9
  end
  continue
end
printf "AFTER_TIMER_PRESSURE\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "TASK_CAPACITY=%u\n", $taskCapacity
printf "FULL_TASK_COUNT=%u\n", `$_full_task_count
printf "FULL_TIMER_COUNT=%u\n", `$_full_timer_count
printf "CURRENT_TIMER_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "FIRST_TIMER_ID=%u\n", `$_first_timer_id
printf "LAST_TIMER_ID=%u\n", `$_last_timer_id
printf "NEXT_TIMER_ID_AFTER_FULL=%u\n", `$_next_timer_id_after_full
printf "REUSE_SLOT_INDEX=%u\n", $reuseSlotIndex
printf "REUSE_TASK_ID=%u\n", `$_reuse_task_id
printf "REUSE_OLD_TIMER_ID=%u\n", `$_reuse_old_timer_id
printf "CANCEL_TIMER_COUNT=%u\n", `$_cancel_timer_count
printf "REUSE_CANCELED_STATE=%u\n", `$_reuse_canceled_state
printf "CANCEL_NEXT_TIMER_ID=%u\n", `$_cancel_next_timer_id
printf "CANCEL_TASK_STATE=%u\n", `$_cancel_task_state
printf "REUSE_NEW_TIMER_ID=%u\n", `$_reuse_new_timer_id
printf "NEXT_TIMER_ID_AFTER_REUSE=%u\n", `$_next_timer_id_after_reuse
printf "REUSE_STATE=%u\n", *(unsigned char*)($reuseTimerAddressExpr+$timerEntryStateOffset)
printf "REUSE_ENTRY_TASK_ID=%u\n", *(unsigned int*)($reuseTimerAddressExpr+$timerEntryTaskIdOffset)
printf "REUSE_TASK_STATE=%u\n", *(unsigned char*)($reuseTaskAddressExpr+$taskStateOffset)
printf "REUSE_NEXT_FIRE=%llu\n", `$_reuse_next_fire
printf "WAKE_COUNT=%u\n", *(unsigned int*)0x$wakeQueueCountAddress
printf "DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
quit
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
    $hitAfter = $gdbOutput.Contains("AFTER_TIMER_PRESSURE")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU timer pressure probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "QEMU timer pressure probe gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "QEMU timer pressure probe did not reach expected breakpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$fullTaskCount = Extract-IntValue -Text $gdbOutput -Name "FULL_TASK_COUNT"
$fullTimerCount = Extract-IntValue -Text $gdbOutput -Name "FULL_TIMER_COUNT"
$currentTimerCount = Extract-IntValue -Text $gdbOutput -Name "CURRENT_TIMER_COUNT"
$firstTimerId = Extract-IntValue -Text $gdbOutput -Name "FIRST_TIMER_ID"
$lastTimerId = Extract-IntValue -Text $gdbOutput -Name "LAST_TIMER_ID"
$nextTimerIdAfterFull = Extract-IntValue -Text $gdbOutput -Name "NEXT_TIMER_ID_AFTER_FULL"
$reuseTaskId = Extract-IntValue -Text $gdbOutput -Name "REUSE_TASK_ID"
$reuseOldTimerId = Extract-IntValue -Text $gdbOutput -Name "REUSE_OLD_TIMER_ID"
$cancelTimerCount = Extract-IntValue -Text $gdbOutput -Name "CANCEL_TIMER_COUNT"
$reuseCanceledState = Extract-IntValue -Text $gdbOutput -Name "REUSE_CANCELED_STATE"
$cancelNextTimerId = Extract-IntValue -Text $gdbOutput -Name "CANCEL_NEXT_TIMER_ID"
$cancelTaskState = Extract-IntValue -Text $gdbOutput -Name "CANCEL_TASK_STATE"
$reuseNewTimerId = Extract-IntValue -Text $gdbOutput -Name "REUSE_NEW_TIMER_ID"
$nextTimerIdAfterReuse = Extract-IntValue -Text $gdbOutput -Name "NEXT_TIMER_ID_AFTER_REUSE"
$reuseState = Extract-IntValue -Text $gdbOutput -Name "REUSE_STATE"
$reuseEntryTaskId = Extract-IntValue -Text $gdbOutput -Name "REUSE_ENTRY_TASK_ID"
$reuseTaskState = Extract-IntValue -Text $gdbOutput -Name "REUSE_TASK_STATE"
$reuseNextFire = Extract-IntValue -Text $gdbOutput -Name "REUSE_NEXT_FIRE"
$wakeCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_COUNT"
$dispatchCount = Extract-IntValue -Text $gdbOutput -Name "DISPATCH_COUNT"

if ($ack -ne 38) { throw "Expected ACK=38, found $ack" }
if ($lastOpcode -ne $timerScheduleOpcode) { throw "Expected LAST_OPCODE=$timerScheduleOpcode, found $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, found $lastResult" }
if ($fullTaskCount -ne $taskCapacity) { throw "Expected FULL_TASK_COUNT=$taskCapacity, found $fullTaskCount" }
if ($fullTimerCount -ne $taskCapacity) { throw "Expected FULL_TIMER_COUNT=$taskCapacity, found $fullTimerCount" }
if ($currentTimerCount -ne $taskCapacity) { throw "Expected CURRENT_TIMER_COUNT=$taskCapacity, found $currentTimerCount" }
if ($firstTimerId -ne 1) { throw "Expected FIRST_TIMER_ID=1, found $firstTimerId" }
if ($lastTimerId -ne $taskCapacity) { throw "Expected LAST_TIMER_ID=$taskCapacity, found $lastTimerId" }
if ($nextTimerIdAfterFull -ne ($taskCapacity + 1)) { throw "Expected NEXT_TIMER_ID_AFTER_FULL=$($taskCapacity + 1), found $nextTimerIdAfterFull" }
if ($reuseTaskId -le 0) { throw "Expected REUSE_TASK_ID>0, found $reuseTaskId" }
if ($reuseOldTimerId -ne ($reuseSlotIndex + 1)) { throw "Expected REUSE_OLD_TIMER_ID=$($reuseSlotIndex + 1), found $reuseOldTimerId" }
if ($cancelTimerCount -ne ($taskCapacity - 1)) { throw "Expected CANCEL_TIMER_COUNT=$($taskCapacity - 1), found $cancelTimerCount" }
if ($reuseCanceledState -ne $timerEntryStateCanceled) { throw "Expected REUSE_CANCELED_STATE=$timerEntryStateCanceled, found $reuseCanceledState" }
if ($cancelNextTimerId -ne ($taskCapacity + 1)) { throw "Expected CANCEL_NEXT_TIMER_ID=$($taskCapacity + 1), found $cancelNextTimerId" }
if ($cancelTaskState -ne $taskStateWaiting) { throw "Expected CANCEL_TASK_STATE=$taskStateWaiting, found $cancelTaskState" }
if ($reuseNewTimerId -ne ($taskCapacity + 1)) { throw "Expected REUSE_NEW_TIMER_ID=$($taskCapacity + 1), found $reuseNewTimerId" }
if ($nextTimerIdAfterReuse -ne ($taskCapacity + 2)) { throw "Expected NEXT_TIMER_ID_AFTER_REUSE=$($taskCapacity + 2), found $nextTimerIdAfterReuse" }
if ($reuseState -ne $timerEntryStateArmed) { throw "Expected REUSE_STATE=$timerEntryStateArmed, found $reuseState" }
if ($reuseEntryTaskId -ne $reuseTaskId) { throw "Expected REUSE_ENTRY_TASK_ID=$reuseTaskId, found $reuseEntryTaskId" }
if ($reuseTaskState -ne $taskStateWaiting) { throw "Expected REUSE_TASK_STATE=$taskStateWaiting, found $reuseTaskState" }
if ($reuseNextFire -le $ticks) { throw "Expected REUSE_NEXT_FIRE>$ticks, found $reuseNextFire" }
if ($wakeCount -ne 0) { throw "Expected WAKE_COUNT=0, found $wakeCount" }
if ($dispatchCount -ne 0) { throw "Expected DISPATCH_COUNT=0, found $dispatchCount" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_TIMER_PRESSURE_PROBE=pass"
Write-Output $gdbOutput.TrimEnd()

