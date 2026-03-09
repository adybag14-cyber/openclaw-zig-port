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
$timerResetOpcode = 41
$wakeQueueClearOpcode = 44
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskWaitForOpcode = 53
$timerDisableOpcode = 47
$timerEnableOpcode = 46

$taskBudget = 6
$taskPriority = 0
$timerDelay = 2
$pauseTicks = 4
$settleTicks = 2

$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonTimer = 1

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
$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetOffset = 12
$taskBudgetRemainingOffset = 16

$timerEnabledOffset = 0
$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerDispatchCountOffset = 8
$timerLastWakeTickOffset = 32
$timerQuantumOffset = 40

$timerEntryTimerIdOffset = 0
$timerEntryTaskIdOffset = 4
$timerEntryStateOffset = 8
$timerEntryReasonOffset = 9
$timerEntryFlagsOffset = 10
$timerEntryPeriodTicksOffset = 12
$timerEntryNextFireTickOffset = 16
$timerEntryFireCountOffset = 24
$timerEntryLastFireTickOffset = 32

$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventTimerIdOffset = 8
$wakeEventReasonOffset = 12
$wakeEventVectorOffset = 13
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
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-timer-disable-reenable-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-timer-disable-reenable.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-timer-disable-reenable.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-timer-disable-reenable.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-timer-disable-reenable-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-timer-disable-reenable-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-timer-disable-reenable-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-timer-disable-reenable-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-timer-disable-reenable-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-timer-disable-reenable" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for timer disable/re-enable runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for timer disable/re-enable PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for timer disable/re-enable PVH artifact failed with exit code $LASTEXITCODE"
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
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName 'baremetal_main.wake_queue'
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName 'baremetal_main.wake_queue_count'
$artifactForGdb = $artifact.Replace('\', '/')
$task0AddressExpr = "0x$schedulerTasksAddress"

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_task_id = 0
set `$_armed_tick = 0
set `$_armed_timer_id = 0
set `$_armed_entry_count = 0
set `$_armed_task_state = 0
set `$_disabled_tick = 0
set `$_pause_target_tick = 0
set `$_paused_tick = 0
set `$_paused_wake_count = 0
set `$_paused_dispatch_count = 0
set `$_paused_entry_count = 0
set `$_paused_task_state = 0
set `$_post_wake_tick = 0
set `$_settle_target_tick = 0
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
    set *(unsigned char*)(0x$statusAddress+$statusModeOffset) = 1
    set *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset) = 0
    set *(short*)(0x$statusAddress+$statusLastCommandResultOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) = 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = 0
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set `$_stage = 1
  end
  continue
end
if `$_stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set `$_stage = 2
  end
  continue
end
if `$_stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set `$_stage = 3
  end
  continue
end
if `$_stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set `$_stage = 4
  end
  continue
end
if `$_stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 1
    set `$_task_id = *(unsigned int*)($task0AddressExpr+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timerDelay
    set `$_stage = 6
  end
  continue
end
if `$_stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)0x$wakeQueueCountAddress == 0 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 1 && *(unsigned char*)($task0AddressExpr+$taskStateOffset) == $taskStateWaiting
    set `$_armed_tick = *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryNextFireTickOffset)
    set `$_armed_timer_id = *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
    set `$_armed_entry_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_armed_task_state = *(unsigned char*)($task0AddressExpr+$taskStateOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set `$_stage = 7
  end
  continue
end
if `$_stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 0
    set `$_disabled_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$_pause_target_tick = `$_armed_tick + $pauseTicks
    set `$_stage = 8
  end
  continue
end
if `$_stage == 8
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= `$_pause_target_tick && *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) > `$_armed_tick && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 0 && *(unsigned int*)0x$wakeQueueCountAddress == 0 && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == 0 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 1 && *(unsigned char*)($task0AddressExpr+$taskStateOffset) == $taskStateWaiting && *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryNextFireTickOffset) == `$_armed_tick
    set `$_paused_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$_paused_wake_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_paused_dispatch_count = *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    set `$_paused_entry_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_paused_task_state = *(unsigned char*)($task0AddressExpr+$taskStateOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerEnableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set `$_stage = 9
  end
  continue
end
if `$_stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 1
    set `$_stage = 10
  end
  continue
end
if `$_stage == 10
  if *(unsigned int*)0x$wakeQueueCountAddress == 1 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 0 && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == 1 && *(unsigned char*)($task0AddressExpr+$taskStateOffset) == $taskStateReady
    set `$_post_wake_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$_settle_target_tick = `$_post_wake_tick + $settleTicks
    set `$_stage = 11
  end
  continue
end
if `$_stage == 11
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= `$_settle_target_tick && *(unsigned int*)0x$wakeQueueCountAddress == 1 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 0 && *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset) == 1 && *(unsigned char*)($task0AddressExpr+$taskStateOffset) == $taskStateReady
    set `$_stage = 12
  end
  continue
end
printf "AFTER_TIMER_DISABLE_REENABLE\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
printf "SCHED_TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "TASK0_ID=%u\n", *(unsigned int*)($task0AddressExpr+$taskIdOffset)
printf "TASK0_STATE=%u\n", *(unsigned char*)($task0AddressExpr+$taskStateOffset)
printf "TASK0_PRIORITY=%u\n", *(unsigned char*)($task0AddressExpr+$taskPriorityOffset)
printf "TASK0_RUN_COUNT=%u\n", *(unsigned int*)($task0AddressExpr+$taskRunCountOffset)
printf "TASK0_BUDGET=%u\n", *(unsigned int*)($task0AddressExpr+$taskBudgetOffset)
printf "TASK0_BUDGET_REMAINING=%u\n", *(unsigned int*)($task0AddressExpr+$taskBudgetRemainingOffset)
printf "ARMED_TICK=%llu\n", `$_armed_tick
printf "ARMED_TIMER_ID=%u\n", `$_armed_timer_id
printf "ARMED_ENTRY_COUNT=%u\n", `$_armed_entry_count
printf "ARMED_TASK_STATE=%u\n", `$_armed_task_state
printf "DISABLED_TICK=%llu\n", `$_disabled_tick
printf "PAUSED_TICK=%llu\n", `$_paused_tick
printf "PAUSED_WAKE_COUNT=%u\n", `$_paused_wake_count
printf "PAUSED_DISPATCH_COUNT=%llu\n", `$_paused_dispatch_count
printf "PAUSED_ENTRY_COUNT=%u\n", `$_paused_entry_count
printf "PAUSED_TASK_STATE=%u\n", `$_paused_task_state
printf "POST_WAKE_TICK=%llu\n", `$_post_wake_tick
printf "TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
printf "TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
printf "TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
printf "TIMER_LAST_WAKE_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
printf "TIMER_QUANTUM=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)0x$wakeQueueCountAddress
printf "TIMER0_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
printf "TIMER0_TASK_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTaskIdOffset)
printf "TIMER0_STATE=%u\n", *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset)
printf "TIMER0_REASON=%u\n", *(unsigned char*)(0x$timerEntriesAddress+$timerEntryReasonOffset)
printf "TIMER0_FLAGS=%u\n", *(unsigned short*)(0x$timerEntriesAddress+$timerEntryFlagsOffset)
printf "TIMER0_PERIOD_TICKS=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryPeriodTicksOffset)
printf "TIMER0_NEXT_FIRE_TICK=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryNextFireTickOffset)
printf "TIMER0_FIRE_COUNT=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryFireCountOffset)
printf "TIMER0_LAST_FIRE_TICK=%llu\n", *(unsigned long long*)(0x$timerEntriesAddress+$timerEntryLastFireTickOffset)
printf "WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
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
    $hitAfter = $gdbOutput.Contains("AFTER_TIMER_DISABLE_REENABLE")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU timer disable/re-enable probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "QEMU timer disable/re-enable probe gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "QEMU timer disable/re-enable probe did not reach expected breakpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$mailboxOpcode = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_OPCODE"
$mailboxSeq = Extract-IntValue -Text $gdbOutput -Name "MAILBOX_SEQ"
$schedulerTaskCount = Extract-IntValue -Text $gdbOutput -Name "SCHED_TASK_COUNT"
$task0Id = Extract-IntValue -Text $gdbOutput -Name "TASK0_ID"
$task0State = Extract-IntValue -Text $gdbOutput -Name "TASK0_STATE"
$task0Priority = Extract-IntValue -Text $gdbOutput -Name "TASK0_PRIORITY"
$task0RunCount = Extract-IntValue -Text $gdbOutput -Name "TASK0_RUN_COUNT"
$task0Budget = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET"
$task0BudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET_REMAINING"
$armedTick = Extract-IntValue -Text $gdbOutput -Name "ARMED_TICK"
$armedTimerId = Extract-IntValue -Text $gdbOutput -Name "ARMED_TIMER_ID"
$armedEntryCount = Extract-IntValue -Text $gdbOutput -Name "ARMED_ENTRY_COUNT"
$armedTaskState = Extract-IntValue -Text $gdbOutput -Name "ARMED_TASK_STATE"
$disabledTick = Extract-IntValue -Text $gdbOutput -Name "DISABLED_TICK"
$pausedTick = Extract-IntValue -Text $gdbOutput -Name "PAUSED_TICK"
$pausedWakeCount = Extract-IntValue -Text $gdbOutput -Name "PAUSED_WAKE_COUNT"
$pausedDispatchCount = Extract-IntValue -Text $gdbOutput -Name "PAUSED_DISPATCH_COUNT"
$pausedEntryCount = Extract-IntValue -Text $gdbOutput -Name "PAUSED_ENTRY_COUNT"
$pausedTaskState = Extract-IntValue -Text $gdbOutput -Name "PAUSED_TASK_STATE"
$postWakeTick = Extract-IntValue -Text $gdbOutput -Name "POST_WAKE_TICK"
$timerEnabled = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENABLED"
$timerEntryCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_ENTRY_COUNT"
$pendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "PENDING_WAKE_COUNT"
$timerDispatchCount = Extract-IntValue -Text $gdbOutput -Name "TIMER_DISPATCH_COUNT"
$timerLastWakeTick = Extract-IntValue -Text $gdbOutput -Name "TIMER_LAST_WAKE_TICK"
$timerQuantum = Extract-IntValue -Text $gdbOutput -Name "TIMER_QUANTUM"
$wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
$timer0Id = Extract-IntValue -Text $gdbOutput -Name "TIMER0_ID"
$timer0TaskId = Extract-IntValue -Text $gdbOutput -Name "TIMER0_TASK_ID"
$timer0State = Extract-IntValue -Text $gdbOutput -Name "TIMER0_STATE"
$timer0Reason = Extract-IntValue -Text $gdbOutput -Name "TIMER0_REASON"
$timer0Flags = Extract-IntValue -Text $gdbOutput -Name "TIMER0_FLAGS"
$timer0PeriodTicks = Extract-IntValue -Text $gdbOutput -Name "TIMER0_PERIOD_TICKS"
$timer0NextFireTick = Extract-IntValue -Text $gdbOutput -Name "TIMER0_NEXT_FIRE_TICK"
$timer0FireCount = Extract-IntValue -Text $gdbOutput -Name "TIMER0_FIRE_COUNT"
$timer0LastFireTick = Extract-IntValue -Text $gdbOutput -Name "TIMER0_LAST_FIRE_TICK"
$wake0Seq = Extract-IntValue -Text $gdbOutput -Name "WAKE0_SEQ"
$wake0TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TASK_ID"
$wake0TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TIMER_ID"
$wake0Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE0_REASON"
$wake0Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE0_VECTOR"
$wake0Tick = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TICK"

$checks = @(
    ($ack -eq 8),
    ($lastOpcode -eq $timerEnableOpcode),
    ($lastResult -eq 0),
    ($ticks -ge ($postWakeTick + $settleTicks)),
    ($mailboxOpcode -eq $timerEnableOpcode),
    ($mailboxSeq -eq 8),
    ($schedulerTaskCount -eq 1),
    ($task0Id -eq 1),
    ($task0State -eq $taskStateReady),
    ($task0Priority -eq $taskPriority),
    ($task0RunCount -eq 0),
    ($task0Budget -eq $taskBudget),
    ($task0BudgetRemaining -eq $taskBudget),
    ($armedTick -gt 0),
    ($armedTimerId -eq 1),
    ($armedEntryCount -eq 1),
    ($armedTaskState -eq $taskStateWaiting),
    ($disabledTick -le $armedTick),
    ($pausedTick -gt $armedTick),
    ($pausedWakeCount -eq 0),
    ($pausedDispatchCount -eq 0),
    ($pausedEntryCount -eq 1),
    ($pausedTaskState -eq $taskStateWaiting),
    ($postWakeTick -gt $pausedTick),
    ($timerEnabled -eq 1),
    ($timerEntryCount -eq 0),
    ($pendingWakeCount -eq 1),
    ($timerDispatchCount -eq 1),
    ($wakeQueueCount -eq 1),
    ($timerLastWakeTick -eq $wake0Tick),
    ($timer0Id -eq $armedTimerId),
    ($timer0TaskId -eq $task0Id),
    ($timer0State -eq 2),
    ($timer0Reason -eq $wakeReasonTimer),
    ($timer0Flags -eq 0),
    ($timer0PeriodTicks -eq 0),
    ($timer0NextFireTick -eq $armedTick),
    ($timer0FireCount -eq 1),
    ($timer0LastFireTick -eq $wake0Tick),
    ($wake0Seq -eq 1),
    ($wake0TaskId -eq $task0Id),
    ($wake0TimerId -eq $armedTimerId),
    ($wake0Reason -eq $wakeReasonTimer),
    ($wake0Vector -eq 0),
    ($wake0Tick -eq $timer0LastFireTick)
)

if ($checks -contains $false) {
    throw "QEMU timer disable/re-enable probe reported unexpected values.`n$gdbOutput"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_GDB_AVAILABLE=True"
Write-Output "BAREMETAL_NM_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_TIMER_DISABLE_REENABLE_PROBE=pass"
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "ARMED_TICK=$armedTick"
Write-Output "ARMED_TASK_STATE=$armedTaskState"
Write-Output "DISABLED_TICK=$disabledTick"
Write-Output "PAUSED_TICK=$pausedTick"
Write-Output "PAUSED_WAKE_COUNT=$pausedWakeCount"
Write-Output "PAUSED_DISPATCH_COUNT=$pausedDispatchCount"
Write-Output "PAUSED_ENTRY_COUNT=$pausedEntryCount"
Write-Output "PAUSED_TASK_STATE=$pausedTaskState"
Write-Output "POST_WAKE_TICK=$postWakeTick"
Write-Output "TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
