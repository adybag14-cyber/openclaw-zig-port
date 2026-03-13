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
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskWaitOpcode = 50
$taskWaitInterruptOpcode = 57
$schedulerWakeTaskOpcode = 45
$triggerInterruptOpcode = 7
$wakeQueuePopReasonVectorOpcode = 62

$taskBudget = 5
$taskPriority = 0
$interruptVectorA = 13
$interruptVectorB = 19
$pairInterrupt13 = 3330

$resultOk = 0
$resultInvalidArgument = -22
$resultNotFound = -2
$modeRunning = 1
$taskStateReady = 1
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

$wakeEventStride = 32
$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-wake-queue-reason-vector-pop-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-wake-queue-reason-vector-pop.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-wake-queue-reason-vector-pop.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-wake-queue-reason-vector-pop.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-wake-queue-reason-vector-pop-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-wake-queue-reason-vector-pop-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-wake-queue-reason-vector-pop-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-wake-queue-reason-vector-pop-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-wake-queue-reason-vector-pop-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-wake-queue-reason-vector-pop" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for wake-queue reason-vector-pop runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for wake-queue reason-vector-pop PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for wake-queue reason-vector-pop PVH artifact failed with exit code $LASTEXITCODE"
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
$artifactForGdb = $artifact.Replace('\', '/')

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_expected_seq = 0
set `$_task1_id = 0
set `$_task2_id = 0
set `$_task3_id = 0
set `$_task4_id = 0
set `$_pre_count = 0
set `$_pre_task0 = 0
set `$_pre_task1 = 0
set `$_pre_task2 = 0
set `$_pre_task3 = 0
set `$_pre_vector0 = 0
set `$_pre_vector1 = 0
set `$_pre_vector2 = 0
set `$_pre_vector3 = 0
set `$_mid_count = 0
set `$_mid_task0 = 0
set `$_mid_task1 = 0
set `$_mid_task2 = 0
set `$_mid_vector0 = 0
set `$_mid_vector1 = 0
set `$_mid_vector2 = 0
set `$_post_count = 0
set `$_post_task0 = 0
set `$_post_task1 = 0
set `$_post_vector0 = 0
set `$_post_vector1 = 0
set `$_final_count = 0
set `$_final_task0 = 0
set `$_final_task1 = 0
set `$_final_vector0 = 0
set `$_final_vector1 = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetInterruptCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 3
  end
  continue
end
if `$_stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 4
  end
  continue
end
if `$_stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)(0x$schedulerTasksAddress + (0 * $taskStride) + $taskIdOffset) != 0
    set `$_task1_id = *(unsigned int*)(0x$schedulerTasksAddress + (0 * $taskStride) + $taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task1_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 6
  end
  continue
end
if `$_stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress + (0 * $taskStride) + $taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task1_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 7
  end
  continue
end
if `$_stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 1 && *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTaskIdOffset) == `$_task1_id && *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventReasonOffset) == $wakeReasonManual
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 8
  end
  continue
end
if `$_stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)(0x$schedulerTasksAddress + (1 * $taskStride) + $taskIdOffset) != 0
    set `$_task2_id = *(unsigned int*)(0x$schedulerTasksAddress + (1 * $taskStride) + $taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task2_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptVectorA
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 9
  end
  continue
end
if `$_stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress + (1 * $taskStride) + $taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVectorA
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 10
  end
  continue
end
if `$_stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 2 && *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventTaskIdOffset) == `$_task2_id && *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventVectorOffset) == $interruptVectorA
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 11
  end
  continue
end
if `$_stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)(0x$schedulerTasksAddress + (2 * $taskStride) + $taskIdOffset) != 0
    set `$_task3_id = *(unsigned int*)(0x$schedulerTasksAddress + (2 * $taskStride) + $taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task3_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptVectorA
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 12
  end
  continue
end
if `$_stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress + (2 * $taskStride) + $taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVectorA
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 13
  end
  continue
end
if `$_stage == 13
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 3 && *(unsigned int*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventTaskIdOffset) == `$_task3_id && *(unsigned char*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventVectorOffset) == $interruptVectorA
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 14
  end
  continue
end
if `$_stage == 14
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)(0x$schedulerTasksAddress + (3 * $taskStride) + $taskIdOffset) != 0
    set `$_task4_id = *(unsigned int*)(0x$schedulerTasksAddress + (3 * $taskStride) + $taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task4_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptVectorB
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 15
  end
  continue
end
if `$_stage == 15
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress + (3 * $taskStride) + $taskStateOffset) == $taskStateWaiting
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVectorB
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 16
  end
  continue
end
if `$_stage == 16
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 4 && *(unsigned int*)(0x$wakeQueueAddress + (3 * $wakeEventStride) + $wakeEventTaskIdOffset) == `$_task4_id && *(unsigned char*)(0x$wakeQueueAddress + (3 * $wakeEventStride) + $wakeEventReasonOffset) == $wakeReasonInterrupt && *(unsigned char*)(0x$wakeQueueAddress + (3 * $wakeEventStride) + $wakeEventVectorOffset) == $interruptVectorB
    set `$_pre_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_pre_task0 = *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_pre_task1 = *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_pre_task2 = *(unsigned int*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_pre_task3 = *(unsigned int*)(0x$wakeQueueAddress + (3 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_pre_vector0 = *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventVectorOffset)
    set `$_pre_vector1 = *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventVectorOffset)
    set `$_pre_vector2 = *(unsigned char*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventVectorOffset)
    set `$_pre_vector3 = *(unsigned char*)(0x$wakeQueueAddress + (3 * $wakeEventStride) + $wakeEventVectorOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopReasonVectorOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $pairInterrupt13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 17
  end
  continue
end
if `$_stage == 17
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 3 && *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventTaskIdOffset) == `$_task3_id && *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventVectorOffset) == $interruptVectorA
    set `$_mid_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_mid_task0 = *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_mid_task1 = *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_mid_task2 = *(unsigned int*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_mid_vector0 = *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventVectorOffset)
    set `$_mid_vector1 = *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventVectorOffset)
    set `$_mid_vector2 = *(unsigned char*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventVectorOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopReasonVectorOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $pairInterrupt13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 9
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 18
  end
  continue
end
if `$_stage == 18
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 2 && *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTaskIdOffset) == `$_task1_id && *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventTaskIdOffset) == `$_task4_id
    set `$_post_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_post_task0 = *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_post_task1 = *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_post_vector0 = *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventVectorOffset)
    set `$_post_vector1 = *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventVectorOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopReasonVectorOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 1
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 19
  end
  continue
end
if `$_stage == 19
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultInvalidArgument && *(unsigned int*)0x$wakeQueueCountAddress == 2
    set `$_final_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_final_task0 = *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_final_task1 = *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventTaskIdOffset)
    set `$_final_vector0 = *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventVectorOffset)
    set `$_final_vector1 = *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventVectorOffset)
    printf "AFTER_WAKE_QUEUE_REASON_VECTOR_POP\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "TASK1_ID=%u\n", `$_task1_id
    printf "TASK2_ID=%u\n", `$_task2_id
    printf "TASK3_ID=%u\n", `$_task3_id
    printf "TASK4_ID=%u\n", `$_task4_id
    printf "PRE_COUNT=%u\n", `$_pre_count
    printf "PRE_TASK0=%u\n", `$_pre_task0
    printf "PRE_TASK1=%u\n", `$_pre_task1
    printf "PRE_TASK2=%u\n", `$_pre_task2
    printf "PRE_TASK3=%u\n", `$_pre_task3
    printf "PRE_VECTOR0=%u\n", `$_pre_vector0
    printf "PRE_VECTOR1=%u\n", `$_pre_vector1
    printf "PRE_VECTOR2=%u\n", `$_pre_vector2
    printf "PRE_VECTOR3=%u\n", `$_pre_vector3
    printf "MID_COUNT=%u\n", `$_mid_count
    printf "MID_TASK0=%u\n", `$_mid_task0
    printf "MID_TASK1=%u\n", `$_mid_task1
    printf "MID_TASK2=%u\n", `$_mid_task2
    printf "MID_VECTOR0=%u\n", `$_mid_vector0
    printf "MID_VECTOR1=%u\n", `$_mid_vector1
    printf "MID_VECTOR2=%u\n", `$_mid_vector2
    printf "POST_COUNT=%u\n", `$_post_count
    printf "POST_TASK0=%u\n", `$_post_task0
    printf "POST_TASK1=%u\n", `$_post_task1
    printf "POST_VECTOR0=%u\n", `$_post_vector0
    printf "POST_VECTOR1=%u\n", `$_post_vector1
    printf "FINAL_COUNT=%u\n", `$_final_count
    printf "FINAL_TASK0=%u\n", `$_final_task0
    printf "FINAL_TASK1=%u\n", `$_final_task1
    printf "FINAL_VECTOR0=%u\n", `$_final_vector0
    printf "FINAL_VECTOR1=%u\n", `$_final_vector1
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
    $hitAfter = $gdbOutput.Contains("AFTER_WAKE_QUEUE_REASON_VECTOR_POP")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU Wake-queue reason-vector-pop probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "Wake-queue reason-vector-pop probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$task1Id = Extract-IntValue -Text $gdbOutput -Name "TASK1_ID"
$task2Id = Extract-IntValue -Text $gdbOutput -Name "TASK2_ID"
$task3Id = Extract-IntValue -Text $gdbOutput -Name "TASK3_ID"
$task4Id = Extract-IntValue -Text $gdbOutput -Name "TASK4_ID"
$preCount = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNT"
$preTask0 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK0"
$preTask1 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK1"
$preTask2 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK2"
$preTask3 = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK3"
$preVector0 = Extract-IntValue -Text $gdbOutput -Name "PRE_VECTOR0"
$preVector1 = Extract-IntValue -Text $gdbOutput -Name "PRE_VECTOR1"
$preVector2 = Extract-IntValue -Text $gdbOutput -Name "PRE_VECTOR2"
$preVector3 = Extract-IntValue -Text $gdbOutput -Name "PRE_VECTOR3"
$midCount = Extract-IntValue -Text $gdbOutput -Name "MID_COUNT"
$midTask0 = Extract-IntValue -Text $gdbOutput -Name "MID_TASK0"
$midTask1 = Extract-IntValue -Text $gdbOutput -Name "MID_TASK1"
$midTask2 = Extract-IntValue -Text $gdbOutput -Name "MID_TASK2"
$midVector0 = Extract-IntValue -Text $gdbOutput -Name "MID_VECTOR0"
$midVector1 = Extract-IntValue -Text $gdbOutput -Name "MID_VECTOR1"
$midVector2 = Extract-IntValue -Text $gdbOutput -Name "MID_VECTOR2"
$postCount = Extract-IntValue -Text $gdbOutput -Name "POST_COUNT"
$postTask0 = Extract-IntValue -Text $gdbOutput -Name "POST_TASK0"
$postTask1 = Extract-IntValue -Text $gdbOutput -Name "POST_TASK1"
$postVector0 = Extract-IntValue -Text $gdbOutput -Name "POST_VECTOR0"
$postVector1 = Extract-IntValue -Text $gdbOutput -Name "POST_VECTOR1"
$finalCount = Extract-IntValue -Text $gdbOutput -Name "FINAL_COUNT"
$finalTask0 = Extract-IntValue -Text $gdbOutput -Name "FINAL_TASK0"
$finalTask1 = Extract-IntValue -Text $gdbOutput -Name "FINAL_TASK1"
$finalVector0 = Extract-IntValue -Text $gdbOutput -Name "FINAL_VECTOR0"
$finalVector1 = Extract-IntValue -Text $gdbOutput -Name "FINAL_VECTOR1"

$expectedAck = 19
if ($ack -ne $expectedAck) { throw "Expected ACK=$expectedAck, got $ack" }
if ($lastOpcode -ne $wakeQueuePopReasonVectorOpcode) { throw "Expected LAST_OPCODE=$wakeQueuePopReasonVectorOpcode, got $lastOpcode" }
if ($lastResult -ne $resultInvalidArgument) { throw "Expected LAST_RESULT=$resultInvalidArgument, got $lastResult" }
if ($ticks -lt $expectedAck) { throw "Expected TICKS >= $expectedAck, got $ticks" }
if ($task1Id -le 0 -or $task2Id -le 0 -or $task3Id -le 0 -or $task4Id -le 0) { throw "Expected all task ids to be positive; got $task1Id,$task2Id,$task3Id,$task4Id" }
if ($preCount -ne 4) { throw "Expected PRE_COUNT=4, got $preCount" }
if ($preTask0 -ne $task1Id) { throw "Expected PRE_TASK0=$task1Id, got $preTask0" }
if ($preTask1 -ne $task2Id) { throw "Expected PRE_TASK1=$task2Id, got $preTask1" }
if ($preTask2 -ne $task3Id) { throw "Expected PRE_TASK2=$task3Id, got $preTask2" }
if ($preTask3 -ne $task4Id) { throw "Expected PRE_TASK3=$task4Id, got $preTask3" }
if ($preVector0 -ne 0) { throw "Expected PRE_VECTOR0=0, got $preVector0" }
if ($preVector1 -ne $interruptVectorA) { throw "Expected PRE_VECTOR1=$interruptVectorA, got $preVector1" }
if ($preVector2 -ne $interruptVectorA) { throw "Expected PRE_VECTOR2=$interruptVectorA, got $preVector2" }
if ($preVector3 -ne $interruptVectorB) { throw "Expected PRE_VECTOR3=$interruptVectorB, got $preVector3" }
if ($midCount -ne 3) { throw "Expected MID_COUNT=3, got $midCount" }
if ($midTask0 -ne $task1Id) { throw "Expected MID_TASK0=$task1Id, got $midTask0" }
if ($midTask1 -ne $task3Id) { throw "Expected MID_TASK1=$task3Id, got $midTask1" }
if ($midTask2 -ne $task4Id) { throw "Expected MID_TASK2=$task4Id, got $midTask2" }
if ($midVector0 -ne 0) { throw "Expected MID_VECTOR0=0, got $midVector0" }
if ($midVector1 -ne $interruptVectorA) { throw "Expected MID_VECTOR1=$interruptVectorA, got $midVector1" }
if ($midVector2 -ne $interruptVectorB) { throw "Expected MID_VECTOR2=$interruptVectorB, got $midVector2" }
if ($postCount -ne 2) { throw "Expected POST_COUNT=2, got $postCount" }
if ($postTask0 -ne $task1Id) { throw "Expected POST_TASK0=$task1Id, got $postTask0" }
if ($postTask1 -ne $task4Id) { throw "Expected POST_TASK1=$task4Id, got $postTask1" }
if ($postVector0 -ne 0) { throw "Expected POST_VECTOR0=0, got $postVector0" }
if ($postVector1 -ne $interruptVectorB) { throw "Expected POST_VECTOR1=$interruptVectorB, got $postVector1" }
if ($finalCount -ne 2) { throw "Expected FINAL_COUNT=2, got $finalCount" }
if ($finalTask0 -ne $task1Id) { throw "Expected FINAL_TASK0=$task1Id, got $finalTask0" }
if ($finalTask1 -ne $task4Id) { throw "Expected FINAL_TASK1=$task4Id, got $finalTask1" }
if ($finalVector0 -ne 0) { throw "Expected FINAL_VECTOR0=0, got $finalVector0" }
if ($finalVector1 -ne $interruptVectorB) { throw "Expected FINAL_VECTOR1=$interruptVectorB, got $finalVector1" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_ACK=$ack"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK1_ID=$task1Id"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK2_ID=$task2Id"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK3_ID=$task3Id"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK4_ID=$task4Id"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_COUNT=$preCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_TASK0=$preTask0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_TASK1=$preTask1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_TASK2=$preTask2"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_TASK3=$preTask3"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_VECTOR0=$preVector0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_VECTOR1=$preVector1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_VECTOR2=$preVector2"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PRE_VECTOR3=$preVector3"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_COUNT=$midCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_TASK0=$midTask0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_TASK1=$midTask1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_TASK2=$midTask2"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_VECTOR0=$midVector0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_VECTOR1=$midVector1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_VECTOR2=$midVector2"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_COUNT=$postCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_TASK0=$postTask0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_TASK1=$postTask1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_VECTOR0=$postVector0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_VECTOR1=$postVector1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_COUNT=$finalCount"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_TASK0=$finalTask0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_TASK1=$finalTask1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_VECTOR0=$finalVector0"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_VECTOR1=$finalVector1"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PROBE=pass"


