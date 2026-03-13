param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1237
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"

$schedulerResetOpcode = 26
$wakeQueueClearOpcode = 44
$schedulerDisableOpcode = 25
$schedulerSetDefaultBudgetOpcode = 30
$taskCreateOpcode = 27
$schedulerSetPolicyOpcode = 55
$schedulerEnableOpcode = 24
$taskSetPriorityOpcode = 56

$defaultBudget = 9
$lowTaskPriority = 1
$highTaskPriority = 9
$highTaskBudget = 6
$reprioritizedLowPriority = 15
$schedulerPriorityPolicy = 1

$taskStateReady = 1
$resultOk = 0

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$schedulerTaskCountOffset = 1
$schedulerDispatchCountOffset = 8
$schedulerDefaultBudgetOffset = 28

$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetOffset = 12
$taskBudgetRemainingOffset = 16

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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-scheduler-priority-budget-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-scheduler-priority-budget-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-scheduler-priority-budget-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-scheduler-priority-budget-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-scheduler-priority-budget-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-scheduler-priority-budget-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-scheduler-priority-budget-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-scheduler-priority-budget-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-scheduler-priority-budget-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-scheduler-priority-budget-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for scheduler-priority-budget probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for scheduler-priority-budget PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for scheduler-priority-budget PVH artifact failed with exit code $LASTEXITCODE"
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
$schedulerPolicyAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_policy$' -SymbolName "baremetal_main.scheduler_policy"
$artifactForGdb = $artifact.Replace('\', '/')

if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$low_id = 0
set `$high_id = 0
set `$default_budget_after_set = 0
set `$low_budget_ticks = 0
set `$low_budget_remaining = 0
set `$high_budget_ticks = 0
set `$high_budget_remaining = 0
set `$low_priority_before = 0
set `$high_priority_before = 0
set `$high_run_before = 0
set `$low_run_before = 0
set `$low_priority_after = 0
set `$low_run_after = 0
set `$high_run_after = 0
set `$invalid_policy_result = 0
set `$policy_after_invalid = 0
set `$invalid_task_result = 0
set `$low_priority_after_invalid = 0
set `$task_count_after_invalid = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerSetDefaultBudgetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $defaultBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned int*)(0x$schedulerStateAddress+$schedulerDefaultBudgetOffset) == $defaultBudget
    set `$default_budget_after_set = *(unsigned int*)(0x$schedulerStateAddress+$schedulerDefaultBudgetOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $lowTaskPriority
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$low_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set `$low_budget_ticks = *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetOffset)
    set `$low_budget_remaining = *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
    set `$low_priority_before = *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $highTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $highTaskPriority
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset) != 0
    set `$high_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset)
    set `$high_budget_ticks = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetOffset)
    set `$high_budget_remaining = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetRemainingOffset)
    set `$high_priority_before = *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskPriorityOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerSetPolicyOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $schedulerPriorityPolicy
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned char*)(0x$schedulerPolicyAddress) == $schedulerPriorityPolicy
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerEnableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset) >= 1 && *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset) == 0
    set `$high_run_before = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset)
    set `$low_run_before = *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskSetPriorityOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$low_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $reprioritizedLowPriority
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9 && *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset) == $reprioritizedLowPriority && *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset) >= 1
    set `$low_priority_after = *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
    set `$low_run_after = *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
    set `$high_run_after = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerSetPolicyOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10
    set `$invalid_policy_result = *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    set `$policy_after_invalid = *(unsigned char*)(0x$schedulerPolicyAddress)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskSetPriorityOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 99999
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 3
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11
    set `$invalid_task_result = *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    set `$low_priority_after_invalid = *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
    set `$task_count_after_invalid = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set `$stage = 12
  end
  continue
end
printf "AFTER_SCHEDULER_PRIORITY_BUDGET\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "DEFAULT_BUDGET=%u\n", `$default_budget_after_set
printf "LOW_ID=%u\n", `$low_id
printf "HIGH_ID=%u\n", `$high_id
printf "LOW_PRIORITY_BEFORE=%u\n", `$low_priority_before
printf "HIGH_PRIORITY_BEFORE=%u\n", `$high_priority_before
printf "LOW_BUDGET_TICKS=%u\n", `$low_budget_ticks
printf "LOW_BUDGET_REMAINING=%u\n", `$low_budget_remaining
printf "HIGH_BUDGET_TICKS=%u\n", `$high_budget_ticks
printf "HIGH_BUDGET_REMAINING=%u\n", `$high_budget_remaining
printf "TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$schedulerStateAddress+$schedulerDispatchCountOffset)
printf "POLICY=%u\n", *(unsigned char*)(0x$schedulerPolicyAddress)
printf "LOW_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "LOW_PRIORITY_AFTER=%u\n", `$low_priority_after
printf "LOW_RUN_BEFORE=%u\n", `$low_run_before
printf "LOW_RUN_AFTER=%u\n", `$low_run_after
printf "HIGH_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
printf "HIGH_RUN_BEFORE=%u\n", `$high_run_before
printf "HIGH_RUN_AFTER=%u\n", `$high_run_after
printf "INVALID_POLICY_RESULT=%d\n", `$invalid_policy_result
printf "POLICY_AFTER_INVALID=%u\n", `$policy_after_invalid
printf "INVALID_TASK_RESULT=%d\n", `$invalid_task_result
printf "LOW_PRIORITY_AFTER_INVALID=%u\n", `$low_priority_after_invalid
printf "TASK_COUNT_AFTER_INVALID=%u\n", `$task_count_after_invalid
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

$gdbOutput = ""
$gdbError = ""
$hitStart = $false
$hitAfter = $false
if (Test-Path $gdbStdout) {
    $gdbOutput = Get-Content -Path $gdbStdout -Raw
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfter = $gdbOutput.Contains("AFTER_SCHEDULER_PRIORITY_BUDGET")
}
if (Test-Path $gdbStderr) {
    $gdbError = Get-Content -Path $gdbStderr -Raw
}

if ($timedOut) {
    throw "QEMU scheduler-priority-budget probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfter) {
    throw "Scheduler-priority-budget probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$defaultBudgetActual = Extract-IntValue -Text $gdbOutput -Name "DEFAULT_BUDGET"
$lowId = Extract-IntValue -Text $gdbOutput -Name "LOW_ID"
$highId = Extract-IntValue -Text $gdbOutput -Name "HIGH_ID"
$lowPriorityBefore = Extract-IntValue -Text $gdbOutput -Name "LOW_PRIORITY_BEFORE"
$highPriorityBefore = Extract-IntValue -Text $gdbOutput -Name "HIGH_PRIORITY_BEFORE"
$lowBudgetTicks = Extract-IntValue -Text $gdbOutput -Name "LOW_BUDGET_TICKS"
$lowBudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "LOW_BUDGET_REMAINING"
$highBudgetTicks = Extract-IntValue -Text $gdbOutput -Name "HIGH_BUDGET_TICKS"
$highBudgetRemaining = Extract-IntValue -Text $gdbOutput -Name "HIGH_BUDGET_REMAINING"
$taskCount = Extract-IntValue -Text $gdbOutput -Name "TASK_COUNT"
$dispatchCount = Extract-IntValue -Text $gdbOutput -Name "DISPATCH_COUNT"
$policy = Extract-IntValue -Text $gdbOutput -Name "POLICY"
$lowState = Extract-IntValue -Text $gdbOutput -Name "LOW_STATE"
$lowPriorityAfter = Extract-IntValue -Text $gdbOutput -Name "LOW_PRIORITY_AFTER"
$lowRunBefore = Extract-IntValue -Text $gdbOutput -Name "LOW_RUN_BEFORE"
$lowRunAfter = Extract-IntValue -Text $gdbOutput -Name "LOW_RUN_AFTER"
$highState = Extract-IntValue -Text $gdbOutput -Name "HIGH_STATE"
$highRunBefore = Extract-IntValue -Text $gdbOutput -Name "HIGH_RUN_BEFORE"
$highRunAfter = Extract-IntValue -Text $gdbOutput -Name "HIGH_RUN_AFTER"
$invalidPolicyResult = Extract-IntValue -Text $gdbOutput -Name "INVALID_POLICY_RESULT"
$policyAfterInvalid = Extract-IntValue -Text $gdbOutput -Name "POLICY_AFTER_INVALID"
$invalidTaskResult = Extract-IntValue -Text $gdbOutput -Name "INVALID_TASK_RESULT"
$lowPriorityAfterInvalid = Extract-IntValue -Text $gdbOutput -Name "LOW_PRIORITY_AFTER_INVALID"
$taskCountAfterInvalid = Extract-IntValue -Text $gdbOutput -Name "TASK_COUNT_AFTER_INVALID"

if ($ack -ne 11) { throw "Expected ACK=11, got $ack" }
if ($lastOpcode -ne $taskSetPriorityOpcode) { throw "Expected LAST_OPCODE=$taskSetPriorityOpcode, got $lastOpcode" }
if ($lastResult -ne -2) { throw "Expected LAST_RESULT=-2, got $lastResult" }
if ($ticks -lt 10) { throw "Expected TICKS >= 10, got $ticks" }
if ($defaultBudgetActual -ne $defaultBudget) { throw "Expected DEFAULT_BUDGET=$defaultBudget, got $defaultBudgetActual" }
if ($lowId -le 0) { throw "Expected LOW_ID > 0, got $lowId" }
if ($highId -le 0) { throw "Expected HIGH_ID > 0, got $highId" }
if ($highId -le $lowId) { throw "Expected HIGH_ID > LOW_ID, got LOW_ID=$lowId HIGH_ID=$highId" }
if ($lowPriorityBefore -ne $lowTaskPriority) { throw "Expected LOW_PRIORITY_BEFORE=$lowTaskPriority, got $lowPriorityBefore" }
if ($highPriorityBefore -ne $highTaskPriority) { throw "Expected HIGH_PRIORITY_BEFORE=$highTaskPriority, got $highPriorityBefore" }
if ($lowBudgetTicks -ne $defaultBudget) { throw "Expected LOW_BUDGET_TICKS=$defaultBudget, got $lowBudgetTicks" }
if ($lowBudgetRemaining -ne $defaultBudget) { throw "Expected LOW_BUDGET_REMAINING=$defaultBudget, got $lowBudgetRemaining" }
if ($highBudgetTicks -ne $highTaskBudget) { throw "Expected HIGH_BUDGET_TICKS=$highTaskBudget, got $highBudgetTicks" }
if ($highBudgetRemaining -ne $highTaskBudget) { throw "Expected HIGH_BUDGET_REMAINING=$highTaskBudget, got $highBudgetRemaining" }
if ($taskCount -ne 2) { throw "Expected TASK_COUNT=2, got $taskCount" }
if ($dispatchCount -lt 2) { throw "Expected DISPATCH_COUNT >= 2, got $dispatchCount" }
if ($policy -ne $schedulerPriorityPolicy) { throw "Expected POLICY=$schedulerPriorityPolicy, got $policy" }
if ($lowState -ne $taskStateReady) { throw "Expected LOW_STATE=$taskStateReady, got $lowState" }
if ($lowPriorityAfter -ne $reprioritizedLowPriority) { throw "Expected LOW_PRIORITY_AFTER=$reprioritizedLowPriority, got $lowPriorityAfter" }
if ($lowRunBefore -ne 0) { throw "Expected LOW_RUN_BEFORE=0, got $lowRunBefore" }
if ($lowRunAfter -lt 1) { throw "Expected LOW_RUN_AFTER >= 1, got $lowRunAfter" }
if ($highState -ne $taskStateReady) { throw "Expected HIGH_STATE=$taskStateReady, got $highState" }
if ($highRunBefore -lt 1) { throw "Expected HIGH_RUN_BEFORE >= 1, got $highRunBefore" }
if ($highRunAfter -lt $highRunBefore) { throw "Expected HIGH_RUN_AFTER >= HIGH_RUN_BEFORE, got HIGH_RUN_AFTER=$highRunAfter HIGH_RUN_BEFORE=$highRunBefore" }
if ($invalidPolicyResult -ne -22) { throw "Expected INVALID_POLICY_RESULT=-22, got $invalidPolicyResult" }
if ($policyAfterInvalid -ne $schedulerPriorityPolicy) { throw "Expected POLICY_AFTER_INVALID=$schedulerPriorityPolicy, got $policyAfterInvalid" }
if ($invalidTaskResult -ne -2) { throw "Expected INVALID_TASK_RESULT=-2, got $invalidTaskResult" }
if ($lowPriorityAfterInvalid -ne $reprioritizedLowPriority) { throw "Expected LOW_PRIORITY_AFTER_INVALID=$reprioritizedLowPriority, got $lowPriorityAfterInvalid" }
if ($taskCountAfterInvalid -ne 2) { throw "Expected TASK_COUNT_AFTER_INVALID=2, got $taskCountAfterInvalid" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_PROBE=pass"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_ACK=$ack"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_DEFAULT_BUDGET=$defaultBudgetActual"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_ID=$lowId"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_ID=$highId"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_PRIORITY_BEFORE=$lowPriorityBefore"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_PRIORITY_BEFORE=$highPriorityBefore"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_BUDGET_TICKS=$lowBudgetTicks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_BUDGET_REMAINING=$lowBudgetRemaining"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_BUDGET_TICKS=$highBudgetTicks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_BUDGET_REMAINING=$highBudgetRemaining"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_TASK_COUNT=$taskCount"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_DISPATCH_COUNT=$dispatchCount"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_POLICY=$policy"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_STATE=$lowState"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_RUN_BEFORE=$lowRunBefore"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_RUN_AFTER=$lowRunAfter"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_STATE=$highState"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_RUN_BEFORE=$highRunBefore"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_HIGH_RUN_AFTER=$highRunAfter"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_PRIORITY_AFTER=$lowPriorityAfter"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_INVALID_POLICY_RESULT=$invalidPolicyResult"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_POLICY_AFTER_INVALID=$policyAfterInvalid"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_INVALID_TASK_RESULT=$invalidTaskResult"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_LOW_PRIORITY_AFTER_INVALID=$lowPriorityAfterInvalid"
Write-Output "BAREMETAL_QEMU_SCHEDULER_PRIORITY_BUDGET_TASK_COUNT_AFTER_INVALID=$taskCountAfterInvalid"

