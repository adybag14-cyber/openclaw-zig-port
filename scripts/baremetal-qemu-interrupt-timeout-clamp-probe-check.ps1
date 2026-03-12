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
$taskWaitInterruptForOpcode = 58

$taskBudget = 4
$taskPriority = 0
$timeoutTicks = 5
$maxTick = [UInt64]::MaxValue
$nearMaxTick = $maxTick - 3

$waitConditionNone = 0
$waitConditionInterruptAny = 3
$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonTimer = 1
$resultOk = 0

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetOffset = 12
$taskBudgetRemainingOffset = 16

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

function Extract-UIntValue {
    param(
        [string] $Text,
        [string] $Name
    )

    $pattern = [regex]::Escape($Name) + '=(\d+)'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) {
        return $null
    }

    return [UInt64]::Parse($match.Groups[1].Value)
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-interrupt-timeout-clamp-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-interrupt-timeout-clamp-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-interrupt-timeout-clamp-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-interrupt-timeout-clamp-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-interrupt-timeout-clamp-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-interrupt-timeout-clamp-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-interrupt-timeout-clamp-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-interrupt-timeout-clamp-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-interrupt-timeout-clamp-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-interrupt-timeout-clamp-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for interrupt-timeout-clamp probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for interrupt-timeout-clamp probe PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for interrupt-timeout-clamp probe PVH artifact failed with exit code $LASTEXITCODE"
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
$schedulerWaitKindAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_kind$' -SymbolName "baremetal_main.scheduler_wait_kind"
$schedulerWaitInterruptVectorAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_interrupt_vector$' -SymbolName "baremetal_main.scheduler_wait_interrupt_vector"
$schedulerWaitTimeoutTickAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_timeout_tick$' -SymbolName "baremetal_main.scheduler_wait_timeout_tick"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
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
set `$arm_ticks = 0
set `$armed_wait_timeout = 0
set `$wake_ticks = 0
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
    set *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) = $nearMaxTick
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
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptForOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timeoutTicks
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionInterruptAny && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress) == $maxTick && *(unsigned int*)(0x$wakeQueueCountAddress) == 0
    set `$arm_ticks = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    set `$armed_wait_timeout = *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$wakeQueueCountAddress) == 1 && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady && *(unsigned char*)(0x$schedulerWaitKindAddress) == $waitConditionNone && *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress) == 0
    set `$wake_ticks = *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "AFTER_INTERRUPT_TIMEOUT_CLAMP\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "TASK0_ID=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    printf "TASK0_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
    printf "TASK0_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
    printf "TASK0_RUN_COUNT=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
    printf "TASK0_BUDGET=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetOffset)
    printf "TASK0_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
    printf "ARM_TICKS=%llu\n", `$arm_ticks
    printf "ARMED_WAIT_TIMEOUT=%llu\n", `$armed_wait_timeout
    printf "WAKE_TICKS=%llu\n", `$wake_ticks
    printf "WAIT_KIND0=%u\n", *(unsigned char*)(0x$schedulerWaitKindAddress)
    printf "WAIT_VECTOR0=%u\n", *(unsigned char*)(0x$schedulerWaitInterruptVectorAddress)
    printf "WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x$schedulerWaitTimeoutTickAddress)
    printf "WAKE_QUEUE_COUNT=%u\n", *(unsigned int*)(0x$wakeQueueCountAddress)
    printf "WAKE0_SEQ=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventSeqOffset)
    printf "WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTaskIdOffset)
    printf "WAKE0_TIMER_ID=%u\n", *(unsigned int*)(0x$wakeQueueAddress+$wakeEventTimerIdOffset)
    printf "WAKE0_REASON=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventReasonOffset)
    printf "WAKE0_VECTOR=%u\n", *(unsigned char*)(0x$wakeQueueAddress+$wakeEventVectorOffset)
    printf "WAKE0_TICK=%llu\n", *(unsigned long long*)(0x$wakeQueueAddress+$wakeEventTickOffset)
    quit
  end
  continue
end
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

$gdbOutput = ""
$gdbError = ""
$hitStart = $false
$hitAfter = $false
if (Test-Path $gdbStdout) {
    $gdbOutput = [string](Get-Content -Path $gdbStdout -Raw)
    if (-not [string]::IsNullOrEmpty($gdbOutput)) {
        $hitStart = $gdbOutput.Contains("HIT_START")
        $hitAfter = $gdbOutput.Contains("AFTER_INTERRUPT_TIMEOUT_CLAMP")
    }
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU interrupt-timeout-clamp probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfter) {
    throw "Interrupt-timeout-clamp probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-UIntValue -Text $gdbOutput -Name "TICKS"
$task0Id = Extract-IntValue -Text $gdbOutput -Name "TASK0_ID"
$task0State = Extract-IntValue -Text $gdbOutput -Name "TASK0_STATE"
$task0Priority = Extract-IntValue -Text $gdbOutput -Name "TASK0_PRIORITY"
$task0RunCount = Extract-IntValue -Text $gdbOutput -Name "TASK0_RUN_COUNT"
$task0Budget = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET"
$task0BudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "TASK0_BUDGET_REMAINING"
$armTicks = Extract-UIntValue -Text $gdbOutput -Name "ARM_TICKS"
$armedWaitTimeout = Extract-UIntValue -Text $gdbOutput -Name "ARMED_WAIT_TIMEOUT"
$wakeTicks = Extract-UIntValue -Text $gdbOutput -Name "WAKE_TICKS"
$waitKind0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_KIND0"
$waitVector0 = Extract-IntValue -Text $gdbOutput -Name "WAIT_VECTOR0"
$waitTimeout0 = Extract-UIntValue -Text $gdbOutput -Name "WAIT_TIMEOUT0"
$wakeQueueCount = Extract-IntValue -Text $gdbOutput -Name "WAKE_QUEUE_COUNT"
$wake0Seq = Extract-IntValue -Text $gdbOutput -Name "WAKE0_SEQ"
$wake0TaskId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TASK_ID"
$wake0TimerId = Extract-IntValue -Text $gdbOutput -Name "WAKE0_TIMER_ID"
$wake0Reason = Extract-IntValue -Text $gdbOutput -Name "WAKE0_REASON"
$wake0Vector = Extract-IntValue -Text $gdbOutput -Name "WAKE0_VECTOR"
$wake0Tick = Extract-UIntValue -Text $gdbOutput -Name "WAKE0_TICK"

if ($ack -ne 7) { throw "Expected ACK=7, got $ack" }
if ($lastOpcode -ne $taskWaitInterruptForOpcode) { throw "Expected LAST_OPCODE=$taskWaitInterruptForOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($ticks -ne 0) { throw "Expected TICKS=0 at wake boundary, got $ticks" }
if ($task0Id -le 0) { throw "Expected TASK0_ID > 0, got $task0Id" }
if ($task0State -ne $taskStateReady) { throw "Expected TASK0_STATE=$taskStateReady, got $task0State" }
if ($task0Priority -ne $taskPriority) { throw "Expected TASK0_PRIORITY=$taskPriority, got $task0Priority" }
if ($task0RunCount -ne 0) { throw "Expected TASK0_RUN_COUNT=0, got $task0RunCount" }
if ($task0Budget -ne $taskBudget) { throw "Expected TASK0_BUDGET=$taskBudget, got $task0Budget" }
if ($task0BudgetRemaining -ne $taskBudget) { throw "Expected TASK0_BUDGET_REMAINING=$taskBudget, got $task0BudgetRemaining" }
if ($armTicks -ne $maxTick) { throw "Expected ARM_TICKS=$maxTick, got $armTicks" }
if ($armedWaitTimeout -ne $maxTick) { throw "Expected ARMED_WAIT_TIMEOUT=$maxTick, got $armedWaitTimeout" }
if ($wakeTicks -ne 0) { throw "Expected WAKE_TICKS=0 after clamp-triggered wake, got $wakeTicks" }
if ($waitKind0 -ne $waitConditionNone) { throw "Expected WAIT_KIND0=$waitConditionNone, got $waitKind0" }
if ($waitVector0 -ne 0) { throw "Expected WAIT_VECTOR0=0, got $waitVector0" }
if ($waitTimeout0 -ne 0) { throw "Expected WAIT_TIMEOUT0=0, got $waitTimeout0" }
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1, got $wakeQueueCount" }
if ($wake0Seq -ne 1) { throw "Expected WAKE0_SEQ=1, got $wake0Seq" }
if ($wake0TaskId -ne $task0Id) { throw "Expected WAKE0_TASK_ID=$task0Id, got $wake0TaskId" }
if ($wake0TimerId -ne 0) { throw "Expected WAKE0_TIMER_ID=0, got $wake0TimerId" }
if ($wake0Reason -ne $wakeReasonTimer) { throw "Expected WAKE0_REASON=$wakeReasonTimer, got $wake0Reason" }
if ($wake0Vector -ne 0) { throw "Expected WAKE0_VECTOR=0, got $wake0Vector" }
if ($wake0Tick -ne $maxTick) { throw "Expected WAKE0_TICK=$maxTick, got $wake0Tick" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_PROBE=pass"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ACK=$ack"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_ID=$task0Id"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_STATE=$task0State"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_PRIORITY=$task0Priority"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_RUN_COUNT=$task0RunCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_BUDGET=$task0Budget"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_TASK0_BUDGET_REMAINING=$task0BudgetRemaining"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARM_TICKS=$armTicks"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_ARMED_WAIT_TIMEOUT=$armedWaitTimeout"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE_TICKS=$wakeTicks"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAIT_KIND0=$waitKind0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAIT_VECTOR0=$waitVector0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAIT_TIMEOUT0=$waitTimeout0"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_SEQ=$wake0Seq"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_TASK_ID=$wake0TaskId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_TIMER_ID=$wake0TimerId"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_REASON=$wake0Reason"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_VECTOR=$wake0Vector"
Write-Output "BAREMETAL_QEMU_INTERRUPT_TIMEOUT_CLAMP_WAKE0_TICK=$wake0Tick"
