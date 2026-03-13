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
$resetInterruptCountersOpcode = 8
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskWaitForOpcode = 53
$taskWaitInterruptForOpcode = 58
$timerSetQuantumOpcode = 48
$timerDisableOpcode = 47
$schedulerWakeTaskOpcode = 45
$triggerInterruptOpcode = 7

$timerTaskBudget = 6
$timerTaskPriority = 0
$interruptTaskBudget = 7
$interruptTaskPriority = 1
$timerDelay = 10
$interruptTimeout = 20
$timerQuantum = 5
$idleTicksAfterReset = 25
$interruptVector = 31
$rearmDelay = 3

$waitConditionManual = 1
$waitConditionTimer = 2
$waitConditionInterruptAny = 3

$taskStateWaiting = 6
$wakeReasonInterrupt = 2
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

$timerEnabledOffset = 0
$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerNextTimerIdOffset = 4
$timerDispatchCountOffset = 8
$timerLastWakeTickOffset = 32
$timerQuantumOffset = 40

$timerEntryStride = 40
$timerEntryTimerIdOffset = 0
$timerEntryTaskIdOffset = 4
$timerEntryStateOffset = 8
$timerEntryNextFireTickOffset = 16

$wakeEventStride = 32
$wakeEventTaskIdOffset = 4
$wakeEventTimerIdOffset = 8
$wakeEventReasonOffset = 12
$wakeEventVectorOffset = 13

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
    Write-Output "BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}
$optionsPath = Join-Path $releaseDir "qemu-timer-reset-recovery-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-timer-reset-recovery.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-timer-reset-recovery.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-timer-reset-recovery.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-timer-reset-recovery-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-timer-reset-recovery-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-timer-reset-recovery-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-timer-reset-recovery-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-timer-reset-recovery-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-timer-reset-recovery" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for timer reset recovery runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for timer reset recovery PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for timer reset recovery PVH artifact failed with exit code $LASTEXITCODE"
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
$schedulerWaitKindAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_kind$' -SymbolName 'baremetal_main.scheduler_wait_kind'
$schedulerWaitTimeoutAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_timeout_tick$' -SymbolName 'baremetal_main.scheduler_wait_timeout_tick'
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName 'baremetal_main.timer_state'
$timerEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_entries$' -SymbolName 'baremetal_main.timer_entries'
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName 'baremetal_main.wake_queue_count'
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName 'baremetal_main.wake_queue'
$artifactForGdb = $artifact.Replace('\', '/')
$task0AddressExpr = "0x$schedulerTasksAddress"
$task1AddressExpr = "0x$schedulerTasksAddress+$taskStride"
$waitTimeout0Expr = "0x$schedulerWaitTimeoutAddress"
$waitTimeout1Expr = "0x$schedulerWaitTimeoutAddress+8"
$wake1AddressExpr = "0x$wakeQueueAddress+$wakeEventStride"

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_idle_target_tick = 0
set `$_task0_id = 0
set `$_task1_id = 0
set `$_pre_timer_enabled = 0
set `$_pre_timer_count = 0
set `$_pre_wake_count = 0
set `$_pre_next_timer_id = 0
set `$_pre_quantum = 0
set `$_pre_task0_state = 0
set `$_pre_task1_state = 0
set `$_pre_wait_kind0 = 0
set `$_pre_wait_kind1 = 0
set `$_pre_wait_timeout0 = 0
set `$_pre_wait_timeout1 = 0
set `$_post_timer_enabled = 0
set `$_post_timer_count = 0
set `$_post_wake_count = 0
set `$_post_next_timer_id = 0
set `$_post_dispatch_count = 0
set `$_post_last_wake_tick = 0
set `$_post_quantum = 0
set `$_post_task0_state = 0
set `$_post_task1_state = 0
set `$_post_wait_kind0 = 0
set `$_post_wait_kind1 = 0
set `$_post_wait_timeout0 = 0
set `$_post_wait_timeout1 = 0
set `$_after_idle_wake_count = 0
set `$_after_manual_wake_count = 0
set `$_after_interrupt_wake_count = 0
set `$_rearm_timer_count = 0
set `$_rearm_timer_id = 0
set `$_rearm_next_timer_id = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetInterruptCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set `$_stage = 4
  end
  continue
end
if `$_stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $timerTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timerTaskPriority
    set `$_stage = 6
  end
  continue
end
if `$_stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 1
    set `$_task0_id = *(unsigned int*)($task0AddressExpr+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptTaskPriority
    set `$_stage = 7
  end
  continue
end
if `$_stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 2
    set `$_task1_id = *(unsigned int*)($task1AddressExpr+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task0_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timerDelay
    set `$_stage = 8
  end
  continue
end
if `$_stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task1_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptTimeout
    set `$_stage = 9
  end
  continue
end
if `$_stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerSetQuantumOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $timerQuantum
    set `$_stage = 10
  end
  continue
end
if `$_stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set `$_stage = 11
  end
  continue
end
if `$_stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11 && *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset) == 0
    set `$_pre_timer_enabled = *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
    set `$_pre_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_pre_wake_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_pre_next_timer_id = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set `$_pre_quantum = *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
    set `$_pre_task0_state = *(unsigned char*)($task0AddressExpr+$taskStateOffset)
    set `$_pre_task1_state = *(unsigned char*)($task1AddressExpr+$taskStateOffset)
    set `$_pre_wait_kind0 = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set `$_pre_wait_kind1 = *(unsigned char*)(0x$schedulerWaitKindAddress+1)
    set `$_pre_wait_timeout0 = *(unsigned long long*)($waitTimeout0Expr)
    set `$_pre_wait_timeout1 = *(unsigned long long*)($waitTimeout1Expr)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set `$_stage = 12
  end
  continue
end
if `$_stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 0 && *(unsigned int*)0x$wakeQueueCountAddress == 0
    set `$_post_timer_enabled = *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
    set `$_post_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_post_wake_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_post_next_timer_id = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set `$_post_dispatch_count = *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    set `$_post_last_wake_tick = *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
    set `$_post_quantum = *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
    set `$_post_task0_state = *(unsigned char*)($task0AddressExpr+$taskStateOffset)
    set `$_post_task1_state = *(unsigned char*)($task1AddressExpr+$taskStateOffset)
    set `$_post_wait_kind0 = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set `$_post_wait_kind1 = *(unsigned char*)(0x$schedulerWaitKindAddress+1)
    set `$_post_wait_timeout0 = *(unsigned long long*)($waitTimeout0Expr)
    set `$_post_wait_timeout1 = *(unsigned long long*)($waitTimeout1Expr)
    set `$_idle_target_tick = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) + $idleTicksAfterReset
    set `$_stage = 13
  end
  continue
end
if `$_stage == 13
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= `$_idle_target_tick && *(unsigned int*)0x$wakeQueueCountAddress == 0 && *(unsigned long long*)($waitTimeout1Expr) == 0
    set `$_after_idle_wake_count = *(unsigned int*)0x$wakeQueueCountAddress
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task0_id
    set `$_stage = 14
  end
  continue
end
if `$_stage == 14
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 13 && *(unsigned int*)0x$wakeQueueCountAddress == 1
    set `$_after_manual_wake_count = *(unsigned int*)0x$wakeQueueCountAddress
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 14
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set `$_stage = 15
  end
  continue
end
if `$_stage == 15
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 14 && *(unsigned int*)0x$wakeQueueCountAddress == 2
    set `$_after_interrupt_wake_count = *(unsigned int*)0x$wakeQueueCountAddress
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 15
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task0_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $rearmDelay
    set `$_stage = 16
  end
  continue
end
if `$_stage == 16
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 15 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 1 && *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset) == 1
    set `$_rearm_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_rearm_timer_id = *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
    set `$_rearm_next_timer_id = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set `$_stage = 17
  end
  continue
end
printf "AFTER_TIMER_RESET_RECOVERY\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TASK0_ID=%u\n", `$_task0_id
printf "TASK1_ID=%u\n", `$_task1_id
printf "PRE_TIMER_ENABLED=%u\n", `$_pre_timer_enabled
printf "PRE_TIMER_COUNT=%u\n", `$_pre_timer_count
printf "PRE_WAKE_COUNT=%u\n", `$_pre_wake_count
printf "PRE_NEXT_TIMER_ID=%u\n", `$_pre_next_timer_id
printf "PRE_QUANTUM=%u\n", `$_pre_quantum
printf "PRE_TASK0_STATE=%u\n", `$_pre_task0_state
printf "PRE_TASK1_STATE=%u\n", `$_pre_task1_state
printf "PRE_WAIT_KIND0=%u\n", `$_pre_wait_kind0
printf "PRE_WAIT_KIND1=%u\n", `$_pre_wait_kind1
printf "PRE_WAIT_TIMEOUT0=%llu\n", `$_pre_wait_timeout0
printf "PRE_WAIT_TIMEOUT1=%llu\n", `$_pre_wait_timeout1
printf "POST_TIMER_ENABLED=%u\n", `$_post_timer_enabled
printf "POST_TIMER_COUNT=%u\n", `$_post_timer_count
printf "POST_WAKE_COUNT=%u\n", `$_post_wake_count
printf "POST_NEXT_TIMER_ID=%u\n", `$_post_next_timer_id
printf "POST_DISPATCH_COUNT=%llu\n", `$_post_dispatch_count
printf "POST_LAST_WAKE_TICK=%llu\n", `$_post_last_wake_tick
printf "POST_QUANTUM=%u\n", `$_post_quantum
printf "POST_TASK0_STATE=%u\n", `$_post_task0_state
printf "POST_TASK1_STATE=%u\n", `$_post_task1_state
printf "POST_WAIT_KIND0=%u\n", `$_post_wait_kind0
printf "POST_WAIT_KIND1=%u\n", `$_post_wait_kind1
printf "POST_WAIT_TIMEOUT0=%llu\n", `$_post_wait_timeout0
printf "POST_WAIT_TIMEOUT1=%llu\n", `$_post_wait_timeout1
printf "AFTER_IDLE_WAKE_COUNT=%u\n", `$_after_idle_wake_count
printf "AFTER_MANUAL_WAKE_COUNT=%u\n", `$_after_manual_wake_count
printf "AFTER_INTERRUPT_WAKE_COUNT=%u\n", `$_after_interrupt_wake_count
printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
printf "WAKE1_TASK_ID=%u\n", *(unsigned int*)($wake1AddressExpr+$wakeEventTaskIdOffset)
printf "WAKE1_TIMER_ID=%u\n", *(unsigned int*)($wake1AddressExpr+$wakeEventTimerIdOffset)
printf "WAKE1_REASON=%u\n", *(unsigned char*)($wake1AddressExpr+$wakeEventReasonOffset)
printf "WAKE1_VECTOR=%u\n", *(unsigned char*)($wake1AddressExpr+$wakeEventVectorOffset)
printf "REARM_TIMER_COUNT=%u\n", `$_rearm_timer_count
printf "REARM_TIMER_ID=%u\n", `$_rearm_timer_id
printf "REARM_NEXT_TIMER_ID=%u\n", `$_rearm_next_timer_id
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
    $hitAfter = $gdbOutput.Contains("AFTER_TIMER_RESET_RECOVERY")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU timer reset recovery probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "QEMU timer reset recovery probe gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "QEMU timer reset recovery probe did not reach expected breakpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$task0Id = Extract-IntValue -Text $gdbOutput -Name "TASK0_ID"
$task1Id = Extract-IntValue -Text $gdbOutput -Name "TASK1_ID"
$preTimerEnabled = Extract-IntValue -Text $gdbOutput -Name "PRE_TIMER_ENABLED"
$preTimerCount = Extract-IntValue -Text $gdbOutput -Name "PRE_TIMER_COUNT"
$preWakeCount = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE_COUNT"
$preNextTimerId = Extract-IntValue -Text $gdbOutput -Name "PRE_NEXT_TIMER_ID"
$preQuantum = Extract-IntValue -Text $gdbOutput -Name "PRE_QUANTUM"
$preTask0State = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK0_STATE"
$preTask1State = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK1_STATE"
$preWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "PRE_WAIT_KIND0"
$preWaitKind1 = Extract-IntValue -Text $gdbOutput -Name "PRE_WAIT_KIND1"
$preWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "PRE_WAIT_TIMEOUT0"
$preWaitTimeout1 = Extract-IntValue -Text $gdbOutput -Name "PRE_WAIT_TIMEOUT1"
$postTimerEnabled = Extract-IntValue -Text $gdbOutput -Name "POST_TIMER_ENABLED"
$postTimerCount = Extract-IntValue -Text $gdbOutput -Name "POST_TIMER_COUNT"
$postWakeCount = Extract-IntValue -Text $gdbOutput -Name "POST_WAKE_COUNT"
$postNextTimerId = Extract-IntValue -Text $gdbOutput -Name "POST_NEXT_TIMER_ID"
$postDispatchCount = Extract-IntValue -Text $gdbOutput -Name "POST_DISPATCH_COUNT"
$postLastWakeTick = Extract-IntValue -Text $gdbOutput -Name "POST_LAST_WAKE_TICK"
$postQuantum = Extract-IntValue -Text $gdbOutput -Name "POST_QUANTUM"
$postTask0State = Extract-IntValue -Text $gdbOutput -Name "POST_TASK0_STATE"
$postTask1State = Extract-IntValue -Text $gdbOutput -Name "POST_TASK1_STATE"
$postWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_KIND0"
$postWaitKind1 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_KIND1"
$postWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_TIMEOUT0"
$postWaitTimeout1 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_TIMEOUT1"
$afterIdleWakeCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_IDLE_WAKE_COUNT"
$afterManualWakeCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_MANUAL_WAKE_COUNT"
$afterInterruptWakeCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_WAKE_COUNT"
$wake0TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TASK_ID"
$wake0TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TIMER_ID"
$wake0Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE0_REASON"
$wake0Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE0_VECTOR"
$wake1TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE1_TASK_ID"
$wake1TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE1_TIMER_ID"
$wake1Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE1_REASON"
$wake1Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE1_VECTOR"
$rearmTimerCount = Extract-IntValue -Text $gdbOutput -Name "REARM_TIMER_COUNT"
$rearmTimerId = Extract-IntValue -Text $gdbOutput -Name "REARM_TIMER_ID"
$rearmNextTimerId = Extract-IntValue -Text $gdbOutput -Name "REARM_NEXT_TIMER_ID"

$checks = @(
    ($ack -eq 15),
    ($lastOpcode -eq $taskWaitForOpcode),
    ($lastResult -eq 0),
    ($task0Id -gt 0),
    ($task1Id -gt 0),
    ($preTimerEnabled -eq 0),
    ($preTimerCount -eq 1),
    ($preWakeCount -eq 0),
    ($preNextTimerId -eq 2),
    ($preQuantum -eq $timerQuantum),
    ($preTask0State -eq $taskStateWaiting),
    ($preTask1State -eq $taskStateWaiting),
    ($preWaitKind0 -eq $waitConditionTimer),
    ($preWaitKind1 -eq $waitConditionInterruptAny),
    ($preWaitTimeout0 -eq 0),
    ($preWaitTimeout1 -gt 0),
    ($postTimerEnabled -eq 1),
    ($postTimerCount -eq 0),
    ($postWakeCount -eq 0),
    ($postNextTimerId -eq 1),
    ($postDispatchCount -eq 0),
    ($postLastWakeTick -eq 0),
    ($postQuantum -eq 1),
    ($postTask0State -eq $taskStateWaiting),
    ($postTask1State -eq $taskStateWaiting),
    ($postWaitKind0 -eq $waitConditionManual),
    ($postWaitKind1 -eq $waitConditionInterruptAny),
    ($postWaitTimeout0 -eq 0),
    ($postWaitTimeout1 -eq 0),
    ($afterIdleWakeCount -eq 0),
    ($afterManualWakeCount -eq 1),
    ($afterInterruptWakeCount -eq 2),
    ($wake0TaskId -eq $task0Id),
    ($wake0TimerId -eq 0),
    ($wake0Reason -eq $wakeReasonManual),
    ($wake0Vector -eq 0),
    ($wake1TaskId -eq $task1Id),
    ($wake1TimerId -eq 0),
    ($wake1Reason -eq $wakeReasonInterrupt),
    ($wake1Vector -eq $interruptVector),
    ($rearmTimerCount -eq 1),
    ($rearmTimerId -eq 1),
    ($rearmNextTimerId -eq 2)
)

if ($checks -contains $false) {
    throw "QEMU timer reset recovery probe reported unexpected values.`n$gdbOutput"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_GDB_AVAILABLE=True"
Write-Output "BAREMETAL_NM_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_TIMER_RESET_RECOVERY_PROBE=pass"
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TASK0_ID=$task0Id"
Write-Output "TASK1_ID=$task1Id"
Write-Output "PRE_TIMER_ENABLED=$preTimerEnabled"
Write-Output "PRE_TIMER_COUNT=$preTimerCount"
Write-Output "PRE_WAKE_COUNT=$preWakeCount"
Write-Output "PRE_NEXT_TIMER_ID=$preNextTimerId"
Write-Output "PRE_QUANTUM=$preQuantum"
Write-Output "PRE_TASK0_STATE=$preTask0State"
Write-Output "PRE_TASK1_STATE=$preTask1State"
Write-Output "PRE_WAIT_KIND0=$preWaitKind0"
Write-Output "PRE_WAIT_KIND1=$preWaitKind1"
Write-Output "PRE_WAIT_TIMEOUT0=$preWaitTimeout0"
Write-Output "PRE_WAIT_TIMEOUT1=$preWaitTimeout1"
Write-Output "POST_TIMER_ENABLED=$postTimerEnabled"
Write-Output "POST_TIMER_COUNT=$postTimerCount"
Write-Output "POST_WAKE_COUNT=$postWakeCount"
Write-Output "POST_NEXT_TIMER_ID=$postNextTimerId"
Write-Output "POST_DISPATCH_COUNT=$postDispatchCount"
Write-Output "POST_LAST_WAKE_TICK=$postLastWakeTick"
Write-Output "POST_QUANTUM=$postQuantum"
Write-Output "POST_TASK0_STATE=$postTask0State"
Write-Output "POST_TASK1_STATE=$postTask1State"
Write-Output "POST_WAIT_KIND0=$postWaitKind0"
Write-Output "POST_WAIT_KIND1=$postWaitKind1"
Write-Output "POST_WAIT_TIMEOUT0=$postWaitTimeout0"
Write-Output "POST_WAIT_TIMEOUT1=$postWaitTimeout1"
Write-Output "AFTER_IDLE_WAKE_COUNT=$afterIdleWakeCount"
Write-Output "AFTER_MANUAL_WAKE_COUNT=$afterManualWakeCount"
Write-Output "AFTER_INTERRUPT_WAKE_COUNT=$afterInterruptWakeCount"
Write-Output "WAKE0_TASK_ID=$wake0TaskId"
Write-Output "WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "WAKE0_REASON=$wake0Reason"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "WAKE1_TASK_ID=$wake1TaskId"
Write-Output "WAKE1_TIMER_ID=$wake1TimerId"
Write-Output "WAKE1_REASON=$wake1Reason"
Write-Output "WAKE1_VECTOR=$wake1Vector"
Write-Output "REARM_TIMER_COUNT=$rearmTimerCount"
Write-Output "REARM_TIMER_ID=$rearmTimerId"
Write-Output "REARM_NEXT_TIMER_ID=$rearmNextTimerId"

