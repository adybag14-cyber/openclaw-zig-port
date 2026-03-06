param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$timerResetOpcode = 41
$timerSetQuantumOpcode = 48
$taskCreateOpcode = 27
$taskWaitForOpcode = 53

$timerQuantum = 3
$taskBudget = 9
$taskPriority = 2
$taskWaitDelay = 2

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

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
    Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-timer-wake-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-timer-wake-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-timer-wake-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-timer-wake-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-timer-wake-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-timer-wake-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-timer-wake-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-timer-wake-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-timer-wake-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-timer-wake-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for timer-wake probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for timer-wake probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for timer-wake probe PVH artifact failed with exit code $LASTEXITCODE"
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
$schedulerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_state$' -SymbolName "baremetal_main.scheduler_state"
$schedulerTasksAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_tasks$' -SymbolName "baremetal_main.scheduler_tasks"
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName "baremetal_main.timer_state"
$timerEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_entries$' -SymbolName "baremetal_main.timer_entries"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
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
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerResetOpcode
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerSetQuantumOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $timerQuantum
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskWaitDelay
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset) >= 1 && *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset) == 2
    set `$stage = 6
  end
  continue
end
printf "AFTER_TIMER_WAKE\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
printf "SCHED_TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "TASK0_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
printf "TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "TASK0_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "TASK0_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
printf "TASK0_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetOffset)
printf "TASK0_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
printf "TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
printf "TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
printf "PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
printf "TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
printf "TIMER_LAST_WAKE_TICK=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerLastWakeTickOffset)
printf "TIMER_QUANTUM=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
printf "TIMER0_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTimerIdOffset)
printf "TIMER0_TASK_ID=%u\n", *(unsigned int*)(0x$timerEntriesAddress+$timerEntryTaskIdOffset)
printf "TIMER0_STATE=%u\n", *(unsigned char*)(0x$timerEntriesAddress+$timerEntryStateOffset)
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
$hitAfterTimerWake = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$schedulerTaskCount = $null
$task0Id = $null
$task0State = $null
$task0Priority = $null
$task0RunCount = $null
$task0Budget = $null
$task0BudgetRemaining = $null
$timerEnabled = $null
$timerEntryCount = $null
$pendingWakeCount = $null
$timerDispatchCount = $null
$timerLastWakeTick = $null
$timerQuantumOut = $null
$timer0Id = $null
$timer0TaskId = $null
$timer0State = $null
$timer0NextFireTick = $null
$timer0FireCount = $null
$timer0LastFireTick = $null
$wake0Seq = $null
$wake0TaskId = $null
$wake0TimerId = $null
$wake0Reason = $null
$wake0Vector = $null
$wake0Tick = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterTimerWake = $out -match "AFTER_TIMER_WAKE"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $schedulerTaskCount = Extract-IntValue -Text $out -Name "SCHED_TASK_COUNT"
    $task0Id = Extract-IntValue -Text $out -Name "TASK0_ID"
    $task0State = Extract-IntValue -Text $out -Name "TASK0_STATE"
    $task0Priority = Extract-IntValue -Text $out -Name "TASK0_PRIORITY"
    $task0RunCount = Extract-IntValue -Text $out -Name "TASK0_RUN_COUNT"
    $task0Budget = Extract-IntValue -Text $out -Name "TASK0_BUDGET"
    $task0BudgetRemaining = Extract-IntValue -Text $out -Name "TASK0_BUDGET_REMAINING"
    $timerEnabled = Extract-IntValue -Text $out -Name "TIMER_ENABLED"
    $timerEntryCount = Extract-IntValue -Text $out -Name "TIMER_ENTRY_COUNT"
    $pendingWakeCount = Extract-IntValue -Text $out -Name "PENDING_WAKE_COUNT"
    $timerDispatchCount = Extract-IntValue -Text $out -Name "TIMER_DISPATCH_COUNT"
    $timerLastWakeTick = Extract-IntValue -Text $out -Name "TIMER_LAST_WAKE_TICK"
    $timerQuantumOut = Extract-IntValue -Text $out -Name "TIMER_QUANTUM"
    $timer0Id = Extract-IntValue -Text $out -Name "TIMER0_ID"
    $timer0TaskId = Extract-IntValue -Text $out -Name "TIMER0_TASK_ID"
    $timer0State = Extract-IntValue -Text $out -Name "TIMER0_STATE"
    $timer0NextFireTick = Extract-IntValue -Text $out -Name "TIMER0_NEXT_FIRE_TICK"
    $timer0FireCount = Extract-IntValue -Text $out -Name "TIMER0_FIRE_COUNT"
    $timer0LastFireTick = Extract-IntValue -Text $out -Name "TIMER0_LAST_FIRE_TICK"
    $wake0Seq = Extract-IntValue -Text $out -Name "WAKE0_SEQ"
    $wake0TaskId = Extract-IntValue -Text $out -Name "WAKE0_TASK_ID"
    $wake0TimerId = Extract-IntValue -Text $out -Name "WAKE0_TIMER_ID"
    $wake0Reason = Extract-IntValue -Text $out -Name "WAKE0_REASON"
    $wake0Vector = Extract-IntValue -Text $out -Name "WAKE0_VECTOR"
    $wake0Tick = Extract-IntValue -Text $out -Name "WAKE0_TICK"
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
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_SCHEDULER_STATE_ADDR=0x$schedulerStateAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TASKS_ADDR=0x$schedulerTasksAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER_STATE_ADDR=0x$timerStateAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER_ENTRIES_ADDR=0x$timerEntriesAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_WAKE_QUEUE_ADDR=0x$wakeQueueAddress"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_HIT_AFTER_TIMER_WAKE=$hitAfterTimerWake"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_MAILBOX_OPCODE=$mailboxOpcode"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_MAILBOX_SEQ=$mailboxSeq"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_SCHED_TASK_COUNT=$schedulerTaskCount"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TASK0_STATE=$task0State"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TASK0_PRIORITY=$task0Priority"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TASK0_RUN_COUNT=$task0RunCount"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TASK0_BUDGET=$task0Budget"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER_ENABLED=$timerEnabled"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER_ENTRY_COUNT=$timerEntryCount"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_PENDING_WAKE_COUNT=$pendingWakeCount"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER_DISPATCH_COUNT=$timerDispatchCount"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER_LAST_WAKE_TICK=$timerLastWakeTick"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER_QUANTUM=$timerQuantumOut"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER0_ID=$timer0Id"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER0_TASK_ID=$timer0TaskId"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER0_STATE=$timer0State"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER0_NEXT_FIRE_TICK=$timer0NextFireTick"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER0_FIRE_COUNT=$timer0FireCount"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMER0_LAST_FIRE_TICK=$timer0LastFireTick"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_WAKE0_TICK=$wake0Tick"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and
    $hitAfterTimerWake -and
    (-not $timedOut) -and
    $ack -eq 5 -and
    $lastOpcode -eq $taskWaitForOpcode -and
    $lastResult -eq 0 -and
    $ticks -ge 5 -and
    $mailboxOpcode -eq $taskWaitForOpcode -and
    $mailboxSeq -eq 5 -and
    $schedulerTaskCount -eq 1 -and
    $task0Id -eq 1 -and
    $task0State -eq 1 -and
    $task0Priority -eq $taskPriority -and
    $task0RunCount -eq 0 -and
    $task0Budget -eq $taskBudget -and
    $task0BudgetRemaining -eq $taskBudget -and
    $timerEnabled -eq 1 -and
    $timerEntryCount -eq 0 -and
    $pendingWakeCount -ge 1 -and
    $timerDispatchCount -ge 1 -and
    $timerLastWakeTick -ge 1 -and
    $timerQuantumOut -eq $timerQuantum -and
    $timer0Id -eq 1 -and
    $timer0TaskId -eq 1 -and
    $timer0State -eq 2 -and
    $timer0FireCount -ge 1 -and
    $timer0LastFireTick -ge 1 -and
    $wake0Seq -eq 1 -and
    $wake0TaskId -eq 1 -and
    $wake0TimerId -eq 1 -and
    $wake0Reason -eq 1 -and
    $wake0Vector -eq 0 -and
    $wake0Tick -eq $timer0LastFireTick
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_TIMER_WAKE_PROBE=fail"
if (Test-Path $gdbStdout) {
    Get-Content -Path $gdbStdout -Tail 80
}
if (Test-Path $gdbStderr) {
    Get-Content -Path $gdbStderr -Tail 80
}
if (Test-Path $qemuStderr) {
    Get-Content -Path $qemuStderr -Tail 80
}
exit 1

