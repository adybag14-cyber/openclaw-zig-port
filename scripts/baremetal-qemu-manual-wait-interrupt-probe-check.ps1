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
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskWaitOpcode = 50
$schedulerWakeTaskOpcode = 45
$triggerInterruptOpcode = 7

$taskBudget = 5
$expectedTaskPriority = 0
$interruptVector = 44

$waitConditionManual = 1
$resultOk = 0
$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonManual = 3

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

$interruptStateLastInterruptVectorOffset = 2
$interruptStateInterruptCountOffset = 16

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
    Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-manual-wait-interrupt-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-manual-wait-interrupt-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-manual-wait-interrupt-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-manual-wait-interrupt-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-manual-wait-interrupt-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-manual-wait-interrupt-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-manual-wait-interrupt-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-manual-wait-interrupt-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-manual-wait-interrupt-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-manual-wait-interrupt-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for manual-wait-interrupt probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for manual-wait-interrupt probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for manual-wait-interrupt probe PVH artifact failed with exit code $LASTEXITCODE"
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
$schedulerWaitKindAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_kind$' -SymbolName "baremetal_main.scheduler_wait_kind"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$interruptStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_state$' -SymbolName "baremetal.x86_bootstrap.interrupt_state"
$artifactForGdb = ($artifact -replace '\\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$task_id = 0
set `$wait_state_before_interrupt = 0
set `$wait_task_count_before_interrupt = 0
set `$wait_kind_before_interrupt = 0
set `$after_interrupt_task_state = 0
set `$after_interrupt_task_count = 0
set `$after_interrupt_wait_kind = 0
set `$after_interrupt_wake_queue_len = 0
set `$after_interrupt_interrupt_count = 0
set `$after_interrupt_last_interrupt_vector = 0
set `$manual_wake_task_state = 0
set `$manual_wake_task_count = 0
set `$manual_wake_queue_len = 0
set `$manual_wake_reason = 0
set `$manual_wake_task_id = 0
set `$manual_wake_tick = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetInterruptCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $expectedTaskPriority
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0 && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionManual && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set `$wait_state_before_interrupt = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$wait_task_count_before_interrupt = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$wait_kind_before_interrupt = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0 && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionManual && *(unsigned int*)(0x$wakeQueueCountAddress) == 0 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset) >= 1 && *(unsigned short*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset) == $interruptVector
    set `$after_interrupt_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$after_interrupt_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$after_interrupt_wait_kind = *(unsigned char*)(0x$schedulerWaitKindAddress)
    set `$after_interrupt_wake_queue_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$after_interrupt_interrupt_count = *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
    set `$after_interrupt_last_interrupt_vector = *(unsigned short*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned int*)(0x$wakeQueueCountAddress) == 1
    set `$manual_wake_task_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$manual_wake_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$manual_wake_queue_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$manual_wake_reason = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    set `$manual_wake_task_id = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    set `$manual_wake_tick = *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    set `$stage = 10
  end
  continue
end
printf "AFTER_MANUAL_WAIT_INTERRUPT\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "TASK_ID=%u\n", `$task_id
printf "TASK_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "WAIT_STATE_BEFORE_INTERRUPT=%u\n", `$wait_state_before_interrupt
printf "WAIT_TASK_COUNT_BEFORE_INTERRUPT=%u\n", `$wait_task_count_before_interrupt
printf "WAIT_KIND_BEFORE_INTERRUPT=%u\n", `$wait_kind_before_interrupt
printf "AFTER_INTERRUPT_TASK_STATE=%u\n", `$after_interrupt_task_state
printf "AFTER_INTERRUPT_TASK_COUNT=%u\n", `$after_interrupt_task_count
printf "AFTER_INTERRUPT_WAIT_KIND=%u\n", `$after_interrupt_wait_kind
printf "AFTER_INTERRUPT_WAKE_QUEUE_LEN=%u\n", `$after_interrupt_wake_queue_len
printf "AFTER_INTERRUPT_INTERRUPT_COUNT=%llu\n", `$after_interrupt_interrupt_count
printf "AFTER_INTERRUPT_LAST_INTERRUPT_VECTOR=%u\n", `$after_interrupt_last_interrupt_vector
printf "MANUAL_WAKE_TASK_STATE=%u\n", `$manual_wake_task_state
printf "MANUAL_WAKE_TASK_COUNT=%u\n", `$manual_wake_task_count
printf "MANUAL_WAKE_QUEUE_LEN=%u\n", `$manual_wake_queue_len
printf "MANUAL_WAKE_REASON=%u\n", `$manual_wake_reason
printf "MANUAL_WAKE_TASK_ID=%u\n", `$manual_wake_task_id
printf "MANUAL_WAKE_TICK=%llu\n", `$manual_wake_tick
printf "INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
printf "LAST_INTERRUPT_VECTOR=%u\n", *(unsigned short*)(0x$interruptStateAddress+$interruptStateLastInterruptVectorOffset)
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
$hitAfter = $false
$gdbOutput = ""
$gdbError = ""

if (Test-Path $gdbStdout) {
    $gdbOutput = [string](Get-Content -Path $gdbStdout -Raw)
    if (-not [string]::IsNullOrEmpty($gdbOutput)) {
        $hitStart = $gdbOutput.Contains("HIT_START")
        $hitAfter = $gdbOutput.Contains("AFTER_MANUAL_WAIT_INTERRUPT")
    }
}

if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU manual-wait-interrupt probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfter) {
    throw "Manual-wait-interrupt probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskId = Extract-IntValue -Text $gdbOutput -Name "TASK_ID"
$taskPriority = Extract-IntValue -Text $gdbOutput -Name "TASK_PRIORITY"
$waitStateBeforeInterrupt = Extract-IntValue -Text $gdbOutput -Name "WAIT_STATE_BEFORE_INTERRUPT"
$waitTaskCountBeforeInterrupt = Extract-IntValue -Text $gdbOutput -Name "WAIT_TASK_COUNT_BEFORE_INTERRUPT"
$waitKindBeforeInterrupt = Extract-IntValue -Text $gdbOutput -Name "WAIT_KIND_BEFORE_INTERRUPT"
$afterInterruptTaskState = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_TASK_STATE"
$afterInterruptTaskCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_TASK_COUNT"
$afterInterruptWaitKind = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_WAIT_KIND"
$afterInterruptWakeQueueLen = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_WAKE_QUEUE_LEN"
$afterInterruptInterruptCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_INTERRUPT_COUNT"
$afterInterruptLastInterruptVector = Extract-IntValue -Text $gdbOutput -Name "AFTER_INTERRUPT_LAST_INTERRUPT_VECTOR"
$manualWakeTaskState = Extract-IntValue -Text $gdbOutput -Name "MANUAL_WAKE_TASK_STATE"
$manualWakeTaskCount = Extract-IntValue -Text $gdbOutput -Name "MANUAL_WAKE_TASK_COUNT"
$manualWakeQueueLen = Extract-IntValue -Text $gdbOutput -Name "MANUAL_WAKE_QUEUE_LEN"
$manualWakeReason = Extract-IntValue -Text $gdbOutput -Name "MANUAL_WAKE_REASON"
$manualWakeTaskId = Extract-IntValue -Text $gdbOutput -Name "MANUAL_WAKE_TASK_ID"
$manualWakeTick = Extract-IntValue -Text $gdbOutput -Name "MANUAL_WAKE_TICK"
$interruptCount = Extract-IntValue -Text $gdbOutput -Name "INTERRUPT_COUNT"
$lastInterruptVector = Extract-IntValue -Text $gdbOutput -Name "LAST_INTERRUPT_VECTOR"

if ($ack -ne 9) { throw "Expected ACK=9, got $ack" }
if ($lastOpcode -ne $schedulerWakeTaskOpcode) { throw "Expected LAST_OPCODE=$schedulerWakeTaskOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($ticks -lt 9) { throw "Expected TICKS >= 9, got $ticks" }
if ($taskId -le 0) { throw "Expected TASK_ID > 0, got $taskId" }
if ($taskPriority -ne $expectedTaskPriority) { throw "Expected TASK_PRIORITY=$expectedTaskPriority, got $taskPriority" }
if ($waitStateBeforeInterrupt -ne $taskStateWaiting) { throw "Expected WAIT_STATE_BEFORE_INTERRUPT=$taskStateWaiting, got $waitStateBeforeInterrupt" }
if ($waitTaskCountBeforeInterrupt -ne 0) { throw "Expected WAIT_TASK_COUNT_BEFORE_INTERRUPT=0, got $waitTaskCountBeforeInterrupt" }
if ($waitKindBeforeInterrupt -ne $waitConditionManual) { throw "Expected WAIT_KIND_BEFORE_INTERRUPT=$waitConditionManual, got $waitKindBeforeInterrupt" }
if ($afterInterruptTaskState -ne $taskStateWaiting) { throw "Expected AFTER_INTERRUPT_TASK_STATE=$taskStateWaiting, got $afterInterruptTaskState" }
if ($afterInterruptTaskCount -ne 0) { throw "Expected AFTER_INTERRUPT_TASK_COUNT=0, got $afterInterruptTaskCount" }
if ($afterInterruptWaitKind -ne $waitConditionManual) { throw "Expected AFTER_INTERRUPT_WAIT_KIND=$waitConditionManual, got $afterInterruptWaitKind" }
if ($afterInterruptWakeQueueLen -ne 0) { throw "Expected AFTER_INTERRUPT_WAKE_QUEUE_LEN=0, got $afterInterruptWakeQueueLen" }
if ($afterInterruptInterruptCount -lt 1) { throw "Expected AFTER_INTERRUPT_INTERRUPT_COUNT >= 1, got $afterInterruptInterruptCount" }
if ($afterInterruptLastInterruptVector -ne $interruptVector) { throw "Expected AFTER_INTERRUPT_LAST_INTERRUPT_VECTOR=$interruptVector, got $afterInterruptLastInterruptVector" }
if ($manualWakeTaskState -ne $taskStateReady) { throw "Expected MANUAL_WAKE_TASK_STATE=$taskStateReady, got $manualWakeTaskState" }
if ($manualWakeQueueLen -ne 1) { throw "Expected MANUAL_WAKE_QUEUE_LEN=1, got $manualWakeQueueLen" }
if ($manualWakeReason -ne $wakeReasonManual) { throw "Expected MANUAL_WAKE_REASON=$wakeReasonManual, got $manualWakeReason" }
if ($manualWakeTaskId -ne $taskId) { throw "Expected MANUAL_WAKE_TASK_ID=$taskId, got $manualWakeTaskId" }
if ($manualWakeTick -le 0) { throw "Expected MANUAL_WAKE_TICK > 0, got $manualWakeTick" }
if ($interruptCount -ne $afterInterruptInterruptCount) { throw "Expected INTERRUPT_COUNT to remain $afterInterruptInterruptCount, got $interruptCount" }
if ($lastInterruptVector -ne $interruptVector) { throw "Expected LAST_INTERRUPT_VECTOR=$interruptVector, got $lastInterruptVector" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=pass"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_ACK=$ack"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TASK_ID=$taskId"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TASK_PRIORITY=$taskPriority"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_STATE_BEFORE_INTERRUPT=$waitStateBeforeInterrupt"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_TASK_COUNT_BEFORE_INTERRUPT=$waitTaskCountBeforeInterrupt"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_KIND_BEFORE_INTERRUPT=$waitKindBeforeInterrupt"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_TASK_STATE=$afterInterruptTaskState"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_TASK_COUNT=$afterInterruptTaskCount"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_WAIT_KIND=$afterInterruptWaitKind"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_WAKE_QUEUE_LEN=$afterInterruptWakeQueueLen"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_INTERRUPT_COUNT=$afterInterruptInterruptCount"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_AFTER_INTERRUPT_LAST_VECTOR=$afterInterruptLastInterruptVector"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TASK_STATE=$manualWakeTaskState"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TASK_COUNT=$manualWakeTaskCount"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_QUEUE_LEN=$manualWakeQueueLen"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_REASON=$manualWakeReason"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TASK_ID=$manualWakeTaskId"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_MANUAL_WAKE_TICK=$manualWakeTick"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_INTERRUPT_COUNT=$interruptCount"
Write-Output "BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_INTERRUPT_VECTOR=$lastInterruptVector"
