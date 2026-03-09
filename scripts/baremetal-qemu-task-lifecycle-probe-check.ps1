param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskTerminateOpcode = 28
$wakeQueueClearOpcode = 44
$schedulerWakeTaskOpcode = 45
$taskWaitOpcode = 50
$taskResumeOpcode = 51

$taskBudget = 5
$expectedTaskPriority = 0

$taskStateReady = 1
$taskStateTerminated = 4
$taskStateWaiting = 6
$wakeReasonManual = 3
$resultNotFound = -2

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
    Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-task-lifecycle-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-task-lifecycle-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-task-lifecycle-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-task-lifecycle-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-task-lifecycle-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-task-lifecycle-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-task-lifecycle-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-task-lifecycle-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-task-lifecycle-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-task-lifecycle-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for task-lifecycle probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for task-lifecycle probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for task-lifecycle probe PVH artifact failed with exit code $LASTEXITCODE"
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
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$task_id = 0
set `$wait1_state = 0
set `$wait1_task_count = 0
set `$wake1_len = 0
set `$wake1_state = 0
set `$wake1_reason = 0
set `$wake1_task_id = 0
set `$wake1_tick = 0
set `$wait2_state = 0
set `$wait2_task_count = 0
set `$wake2_len = 0
set `$wake2_state = 0
set `$wake2_reason = 0
set `$wake2_task_id = 0
set `$wake2_tick = 0
set `$terminate_state = 0
set `$terminate_task_count = 0
set `$rejected_wake_len = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueueClearOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
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
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $expectedTaskPriority
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set `$wait1_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$wait1_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady
    set `$wake1_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$wake1_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$wake1_reason = *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    set `$wake1_task_id = *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    set `$wake1_tick = *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set `$wait2_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$wait2_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskResumeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned int*)(0x$wakeQueueCountAddress) == 2 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady
    set `$wake2_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$wake2_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$wake2_reason = *(unsigned char*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventReasonOffset)
    set `$wake2_task_id = *(unsigned int*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTaskIdOffset)
    set `$wake2_tick = *(unsigned long long*)(0x$wakeQueueAddress+($wakeEventStride*1)+$wakeEventTickOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskTerminateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateTerminated && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set `$terminate_state = *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    set `$terminate_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultNotFound && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set `$rejected_wake_len = *(unsigned int*)(0x$wakeQueueCountAddress)
    set `$stage = 11
  end
  continue
end
printf "AFTER_TASK_LIFECYCLE\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "TASK_ID=%u\n", `$task_id
printf "TASK_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "WAIT1_STATE=%u\n", `$wait1_state
printf "WAIT1_TASK_COUNT=%u\n", `$wait1_task_count
printf "WAKE1_QUEUE_LEN=%u\n", `$wake1_len
printf "WAKE1_STATE=%u\n", `$wake1_state
printf "WAKE1_REASON=%u\n", `$wake1_reason
printf "WAKE1_TASK_ID=%u\n", `$wake1_task_id
printf "WAKE1_TICK=%llu\n", `$wake1_tick
printf "WAIT2_STATE=%u\n", `$wait2_state
printf "WAIT2_TASK_COUNT=%u\n", `$wait2_task_count
printf "WAKE2_QUEUE_LEN=%u\n", `$wake2_len
printf "WAKE2_STATE=%u\n", `$wake2_state
printf "WAKE2_REASON=%u\n", `$wake2_reason
printf "WAKE2_TASK_ID=%u\n", `$wake2_task_id
printf "WAKE2_TICK=%llu\n", `$wake2_tick
printf "TERMINATE_STATE=%u\n", `$terminate_state
printf "TERMINATE_TASK_COUNT=%u\n", `$terminate_task_count
printf "REJECTED_WAKE_QUEUE_LEN=%u\n", `$rejected_wake_len
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
$hitAfterLifecycle = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$taskId = $null
$taskPriority = $null
$wait1State = $null
$wait1TaskCount = $null
$wake1QueueLen = $null
$wake1State = $null
$wake1Reason = $null
$wake1TaskId = $null
$wait2State = $null
$wait2TaskCount = $null
$wake2QueueLen = $null
$wake2State = $null
$wake2Reason = $null
$wake2TaskId = $null
$terminateState = $null
$terminateTaskCount = $null
$rejectedWakeQueueLen = $null
$gdbOutput = ""
$gdbError = ""

if (Test-Path $gdbStdout) {
    $gdbOutput = Get-Content -Path $gdbStdout -Raw
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfterLifecycle = $gdbOutput.Contains("AFTER_TASK_LIFECYCLE")
    $ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    $taskId = Extract-IntValue -Text $gdbOutput -Name "TASK_ID"
    $taskPriority = Extract-IntValue -Text $gdbOutput -Name "TASK_PRIORITY"
    $wait1State = Extract-IntValue -Text $gdbOutput -Name "WAIT1_STATE"
    $wait1TaskCount = Extract-IntValue -Text $gdbOutput -Name "WAIT1_TASK_COUNT"
    $wake1QueueLen = Extract-IntValue -Text $gdbOutput -Name "WAKE1_QUEUE_LEN"
    $wake1State = Extract-IntValue -Text $gdbOutput -Name "WAKE1_STATE"
    $wake1Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE1_REASON"
    $wake1TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE1_TASK_ID"
    $wait2State = Extract-IntValue -Text $gdbOutput -Name "WAIT2_STATE"
    $wait2TaskCount = Extract-IntValue -Text $gdbOutput -Name "WAIT2_TASK_COUNT"
    $wake2QueueLen = Extract-IntValue -Text $gdbOutput -Name "WAKE2_QUEUE_LEN"
    $wake2State = Extract-IntValue -Text $gdbOutput -Name "WAKE2_STATE"
    $wake2Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE2_REASON"
    $wake2TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE2_TASK_ID"
    $terminateState = Extract-IntValue -Text $gdbOutput -Name "TERMINATE_STATE"
    $terminateTaskCount = Extract-IntValue -Text $gdbOutput -Name "TERMINATE_TASK_COUNT"
    $rejectedWakeQueueLen = Extract-IntValue -Text $gdbOutput -Name "REJECTED_WAKE_QUEUE_LEN"
}

if (Test-Path $gdbStderr) {
    $gdbError = Get-Content -Path $gdbStderr -Raw
}

if ($timedOut) {
    throw "QEMU task-lifecycle probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }

if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfterLifecycle) {
    throw "Task-lifecycle probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if ($ack -ne 10) { throw "Expected ACK=10, got $ack" }
if ($lastOpcode -ne $schedulerWakeTaskOpcode) { throw "Expected LAST_OPCODE=$schedulerWakeTaskOpcode, got $lastOpcode" }
if ($lastResult -ne $resultNotFound) { throw "Expected LAST_RESULT=$resultNotFound, got $lastResult" }
if ($ticks -lt 10) { throw "Expected TICKS >= 10, got $ticks" }
if ($taskId -le 0) { throw "Expected TASK_ID > 0, got $taskId" }
if ($taskPriority -ne $expectedTaskPriority) { throw "Expected TASK_PRIORITY=$expectedTaskPriority, got $taskPriority" }
if ($wait1State -ne $taskStateWaiting) { throw "Expected WAIT1_STATE=$taskStateWaiting, got $wait1State" }
if ($wait1TaskCount -ne 0) { throw "Expected WAIT1_TASK_COUNT=0, got $wait1TaskCount" }
if ($wake1QueueLen -ne 1) { throw "Expected WAKE1_QUEUE_LEN=1, got $wake1QueueLen" }
if ($wake1State -ne $taskStateReady) { throw "Expected WAKE1_STATE=$taskStateReady, got $wake1State" }
if ($wake1Reason -ne $wakeReasonManual) { throw "Expected WAKE1_REASON=$wakeReasonManual, got $wake1Reason" }
if ($wake1TaskId -ne $taskId) { throw "Expected WAKE1_TASK_ID=$taskId, got $wake1TaskId" }
if ($wait2State -ne $taskStateWaiting) { throw "Expected WAIT2_STATE=$taskStateWaiting, got $wait2State" }
if ($wait2TaskCount -ne 0) { throw "Expected WAIT2_TASK_COUNT=0, got $wait2TaskCount" }
if ($wake2QueueLen -ne 2) { throw "Expected WAKE2_QUEUE_LEN=2, got $wake2QueueLen" }
if ($wake2State -ne $taskStateReady) { throw "Expected WAKE2_STATE=$taskStateReady, got $wake2State" }
if ($wake2Reason -ne $wakeReasonManual) { throw "Expected WAKE2_REASON=$wakeReasonManual, got $wake2Reason" }
if ($wake2TaskId -ne $taskId) { throw "Expected WAKE2_TASK_ID=$taskId, got $wake2TaskId" }
if ($terminateState -ne $taskStateTerminated) { throw "Expected TERMINATE_STATE=$taskStateTerminated, got $terminateState" }
if ($terminateTaskCount -ne 0) { throw "Expected TERMINATE_TASK_COUNT=0, got $terminateTaskCount" }
if ($rejectedWakeQueueLen -ne 0) { throw "Expected REJECTED_WAKE_QUEUE_LEN=0, got $rejectedWakeQueueLen" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_PROBE=pass"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_ID=$taskId"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TASK_PRIORITY=$taskPriority"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_STATE=$wait1State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT1_TASK_COUNT=$wait1TaskCount"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_QUEUE_LEN=$wake1QueueLen"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_STATE=$wake1State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_REASON=$wake1Reason"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE1_TASK_ID=$wake1TaskId"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_STATE=$wait2State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAIT2_TASK_COUNT=$wait2TaskCount"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_QUEUE_LEN=$wake2QueueLen"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_STATE=$wake2State"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_REASON=$wake2Reason"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_WAKE2_TASK_ID=$wake2TaskId"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_STATE=$terminateState"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_TERMINATE_TASK_COUNT=$terminateTaskCount"
Write-Output "BAREMETAL_QEMU_TASK_LIFECYCLE_REJECTED_WAKE_QUEUE_LEN=$rejectedWakeQueueLen"
