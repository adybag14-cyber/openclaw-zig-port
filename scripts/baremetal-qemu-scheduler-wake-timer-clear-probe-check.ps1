param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1321
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$wakeQueueClearOpcode = 44
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$timerSetQuantumOpcode = 48
$taskWaitForOpcode = 53
$schedulerWakeTaskOpcode = 45

$taskBudget = 5
$taskPriority = 0
$timerQuantum = 5
$initialDelay = 10
$rearmDelay = 3
$idleTicksAfterResume = 20

$taskStateReady = 1
$taskStateWaiting = 6
$timerEntryStateCanceled = 3
$wakeReasonManual = 3

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4

$timerEntryCountOffset = 1
$timerNextTimerIdOffset = 4
$timerDispatchCountOffset = 8
$timerQuantumOffset = 40

$timerEntryStride = 40
$timerEntryTimerIdOffset = 0
$timerEntryStateOffset = 8

$wakeEventStride = 32
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-scheduler-wake-timer-clear-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-scheduler-wake-timer-clear-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-scheduler-wake-timer-clear-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-scheduler-wake-timer-clear-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-scheduler-wake-timer-clear-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-scheduler-wake-timer-clear-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-scheduler-wake-timer-clear-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-scheduler-wake-timer-clear-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-scheduler-wake-timer-clear-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-scheduler-wake-timer-clear-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for task-resume timer-clear probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for task-resume timer-clear probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for task-resume timer-clear probe PVH artifact failed with exit code $LASTEXITCODE"
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
$schedulerTasksAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_tasks$' -SymbolName "baremetal_main.scheduler_tasks"
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName "baremetal_main.timer_state"
$timerEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_entries$' -SymbolName "baremetal_main.timer_entries"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$artifactForGdb = $artifact.Replace('\', '/')

foreach ($path in @($gdbStdout, $gdbStderr, $qemuStdout, $qemuStderr)) {
    if (Test-Path $path) { Remove-Item -Force $path }
}

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_task_id = 0
set `$_pre_task_state = 0
set `$_pre_timer_count = 0
set `$_pre_next_timer_id = 0
set `$_post_resume_task_state = 0
set `$_post_resume_timer_count = 0
set `$_post_resume_entry_state = 0
set `$_post_resume_wake_count = 0
set `$_post_resume_wake_reason = 0
set `$_post_resume_next_timer_id = 0
set `$_post_resume_dispatch_count = 0
set `$_post_resume_wake_tick = 0
set `$_post_idle_wake_count = 0
set `$_post_idle_timer_count = 0
set `$_post_idle_dispatch_count = 0
set `$_idle_start_ticks = 0
set `$_rearm_timer_id = 0
set `$_rearm_next_timer_id = 0
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START\n"
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerResetOpcode
set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
set `$_stage = 1
continue
end
break *0x$spinPauseAddress
commands
silent
if `$_stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 2
  end
  continue
end
if `$_stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 3
  end
  continue
end
if `$_stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$_stage = 4
  end
  continue
end
if `$_stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$_task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerSetQuantumOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $timerQuantum
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $initialDelay
    set `$_stage = 6
  end
  continue
end
if `$_stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 1
    set `$_pre_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$_pre_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_pre_next_timer_id = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 7
  end
  continue
end
if `$_stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 0 && *(unsigned int*)(0x$wakeQueueCountAddress) == 1
    set `$_post_resume_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$_post_resume_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_post_resume_entry_state = *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset)
    set `$_post_resume_wake_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$_post_resume_wake_reason = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    set `$_post_resume_next_timer_id = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set `$_post_resume_dispatch_count = *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    set `$_post_resume_wake_tick = *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    set `$_idle_start_ticks = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$_stage = 8
  end
  continue
end
if `$_stage == 8
  if *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) >= `$_idle_start_ticks + $idleTicksAfterResume
    set `$_post_idle_wake_count = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$_post_idle_timer_count = *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    set `$_post_idle_dispatch_count = *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $rearmDelay
    set `$_stage = 9
  end
  continue
end
if `$_stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset) == 1
    set `$_rearm_timer_id = *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
    set `$_rearm_next_timer_id = *(unsigned int*)(0x$timerStateAddress+$timerNextTimerIdOffset)
    set `$_stage = 10
  end
  continue
end
printf "AFTER_SCHEDULER_WAKE_TIMER_CLEAR\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "TASK_ID=%u\n", `$_task_id
printf "PRE_TASK_STATE=%u\n", `$_pre_task_state
printf "PRE_TIMER_COUNT=%u\n", `$_pre_timer_count
printf "PRE_NEXT_TIMER_ID=%u\n", `$_pre_next_timer_id
printf "POST_RESUME_TASK_STATE=%u\n", `$_post_resume_task_state
printf "POST_RESUME_TIMER_COUNT=%u\n", `$_post_resume_timer_count
printf "POST_RESUME_ENTRY_STATE=%u\n", `$_post_resume_entry_state
printf "POST_RESUME_WAKE_COUNT=%u\n", `$_post_resume_wake_count
printf "POST_RESUME_WAKE_REASON=%u\n", `$_post_resume_wake_reason
printf "POST_RESUME_WAKE_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
printf "POST_RESUME_WAKE_TICK=%llu\n", `$_post_resume_wake_tick
printf "POST_RESUME_NEXT_TIMER_ID=%u\n", `$_post_resume_next_timer_id
printf "POST_RESUME_DISPATCH_COUNT=%llu\n", `$_post_resume_dispatch_count
printf "POST_IDLE_WAKE_COUNT=%u\n", `$_post_idle_wake_count
printf "POST_IDLE_TIMER_COUNT=%u\n", `$_post_idle_timer_count
printf "POST_IDLE_DISPATCH_COUNT=%llu\n", `$_post_idle_dispatch_count
printf "POST_IDLE_QUANTUM=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
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
$hitAfterProbe = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$taskId = $null
$preTaskState = $null
$preTimerCount = $null
$preNextTimerId = $null
$postResumeTaskState = $null
$postResumeTimerCount = $null
$postResumeEntryState = $null
$postResumeWakeCount = $null
$postResumeWakeReason = $null
$postResumeWakeTaskId = $null
$postResumeWakeTick = $null
$postResumeNextTimerId = $null
$postResumeDispatchCount = $null
$postIdleWakeCount = $null
$postIdleTimerCount = $null
$postIdleDispatchCount = $null
$postIdleQuantum = $null
$rearmTimerId = $null
$rearmNextTimerId = $null
$gdbOutput = ""
$gdbError = ""

if (Test-Path $gdbStdout) {
    $gdbOutputRaw = Get-Content -Path $gdbStdout -Raw -ErrorAction SilentlyContinue
    $gdbOutput = if ($null -eq $gdbOutputRaw) { "" } else { [string]$gdbOutputRaw }
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfterProbe = $gdbOutput.Contains("AFTER_SCHEDULER_WAKE_TIMER_CLEAR")
    $ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    $taskId = Extract-IntValue -Text $gdbOutput -Name "TASK_ID"
    $preTaskState = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK_STATE"
    $preTimerCount = Extract-IntValue -Text $gdbOutput -Name "PRE_TIMER_COUNT"
    $preNextTimerId = Extract-IntValue -Text $gdbOutput -Name "PRE_NEXT_TIMER_ID"
    $postResumeTaskState = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_TASK_STATE"
    $postResumeTimerCount = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_TIMER_COUNT"
    $postResumeEntryState = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_ENTRY_STATE"
    $postResumeWakeCount = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_WAKE_COUNT"
    $postResumeWakeReason = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_WAKE_REASON"
    $postResumeWakeTaskId = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_WAKE_TASK_ID"
    $postResumeWakeTick = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_WAKE_TICK"
    $postResumeNextTimerId = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_NEXT_TIMER_ID"
    $postResumeDispatchCount = Extract-IntValue -Text $gdbOutput -Name "POST_RESUME_DISPATCH_COUNT"
    $postIdleWakeCount = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_WAKE_COUNT"
    $postIdleTimerCount = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_TIMER_COUNT"
    $postIdleDispatchCount = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_DISPATCH_COUNT"
    $postIdleQuantum = Extract-IntValue -Text $gdbOutput -Name "POST_IDLE_QUANTUM"
    $rearmTimerId = Extract-IntValue -Text $gdbOutput -Name "REARM_TIMER_ID"
    $rearmNextTimerId = Extract-IntValue -Text $gdbOutput -Name "REARM_NEXT_TIMER_ID"
}

if (Test-Path $gdbStderr) {
    $gdbErrorRaw = Get-Content -Path $gdbStderr -Raw -ErrorAction SilentlyContinue
    $gdbError = if ($null -eq $gdbErrorRaw) { "" } else { [string]$gdbErrorRaw }
}

if ($timedOut) {
    throw "QEMU task-resume timer-clear probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfterProbe) {
    throw "Task-resume timer-clear probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if ($ack -ne 8) { throw "Expected ACK=8, got $ack" }
if ($lastOpcode -ne $taskWaitForOpcode) { throw "Expected LAST_OPCODE=$taskWaitForOpcode, got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0, got $lastResult" }
if ($ticks -lt 8) { throw "Expected TICKS >= 8, got $ticks" }
if ($taskId -le 0) { throw "Expected TASK_ID > 0, got $taskId" }
if ($preTaskState -ne $taskStateWaiting) { throw "Expected PRE_TASK_STATE=$taskStateWaiting, got $preTaskState" }
if ($preTimerCount -ne 1) { throw "Expected PRE_TIMER_COUNT=1, got $preTimerCount" }
if ($preNextTimerId -ne 2) { throw "Expected PRE_NEXT_TIMER_ID=2, got $preNextTimerId" }
if ($postResumeTaskState -ne $taskStateReady) { throw "Expected POST_RESUME_TASK_STATE=$taskStateReady, got $postResumeTaskState" }
if ($postResumeTimerCount -ne 0) { throw "Expected POST_RESUME_TIMER_COUNT=0, got $postResumeTimerCount" }
if ($postResumeEntryState -ne $timerEntryStateCanceled) { throw "Expected POST_RESUME_ENTRY_STATE=$timerEntryStateCanceled, got $postResumeEntryState" }
if ($postResumeWakeCount -ne 1) { throw "Expected POST_RESUME_WAKE_COUNT=1, got $postResumeWakeCount" }
if ($postResumeWakeReason -ne $wakeReasonManual) { throw "Expected POST_RESUME_WAKE_REASON=$wakeReasonManual, got $postResumeWakeReason" }
if ($postResumeWakeTaskId -ne $taskId) { throw "Expected POST_RESUME_WAKE_TASK_ID=$taskId, got $postResumeWakeTaskId" }
if ($postResumeNextTimerId -ne 2) { throw "Expected POST_RESUME_NEXT_TIMER_ID=2, got $postResumeNextTimerId" }
if ($postResumeDispatchCount -ne 0) { throw "Expected POST_RESUME_DISPATCH_COUNT=0, got $postResumeDispatchCount" }
if ($postIdleWakeCount -ne 1) { throw "Expected POST_IDLE_WAKE_COUNT=1, got $postIdleWakeCount" }
if ($postIdleTimerCount -ne 0) { throw "Expected POST_IDLE_TIMER_COUNT=0, got $postIdleTimerCount" }
if ($postIdleDispatchCount -ne 0) { throw "Expected POST_IDLE_DISPATCH_COUNT=0, got $postIdleDispatchCount" }
if ($postIdleQuantum -ne $timerQuantum) { throw "Expected POST_IDLE_QUANTUM=$timerQuantum, got $postIdleQuantum" }
if ($rearmTimerId -ne 2) { throw "Expected REARM_TIMER_ID=2, got $rearmTimerId" }
if ($rearmNextTimerId -ne 3) { throw "Expected REARM_NEXT_TIMER_ID=3, got $rearmNextTimerId" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_SCHEDULER_WAKE_TIMER_CLEAR_PROBE=pass"
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TICKS=$ticks"
Write-Output "TASK_ID=$taskId"
Write-Output "PRE_TASK_STATE=$preTaskState"
Write-Output "PRE_TIMER_COUNT=$preTimerCount"
Write-Output "PRE_NEXT_TIMER_ID=$preNextTimerId"
Write-Output "POST_RESUME_TASK_STATE=$postResumeTaskState"
Write-Output "POST_RESUME_TIMER_COUNT=$postResumeTimerCount"
Write-Output "POST_RESUME_ENTRY_STATE=$postResumeEntryState"
Write-Output "POST_RESUME_WAKE_COUNT=$postResumeWakeCount"
Write-Output "POST_RESUME_WAKE_REASON=$postResumeWakeReason"
Write-Output "POST_RESUME_WAKE_TASK_ID=$postResumeWakeTaskId"
Write-Output "POST_RESUME_WAKE_TICK=$postResumeWakeTick"
Write-Output "POST_RESUME_NEXT_TIMER_ID=$postResumeNextTimerId"
Write-Output "POST_RESUME_DISPATCH_COUNT=$postResumeDispatchCount"
Write-Output "POST_IDLE_WAKE_COUNT=$postIdleWakeCount"
Write-Output "POST_IDLE_TIMER_COUNT=$postIdleTimerCount"
Write-Output "POST_IDLE_DISPATCH_COUNT=$postIdleDispatchCount"
Write-Output "POST_IDLE_QUANTUM=$postIdleQuantum"
Write-Output "REARM_TIMER_ID=$rearmTimerId"
Write-Output "REARM_NEXT_TIMER_ID=$rearmNextTimerId"


