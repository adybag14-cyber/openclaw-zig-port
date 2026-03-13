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
$taskCreateOpcode = 27
$schedulerEnableOpcode = 24

$firstTaskBudget = 4
$secondTaskBudget = 4
$firstTaskPriority = 1
$secondTaskPriority = 9

$taskStateReady = 1
$resultOk = 0
$schedulerRoundRobinPolicy = 0

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

$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetTicksOffset = 12
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_PROBE=skipped"
    return
}

if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-scheduler-round-robin-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-scheduler-round-robin-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-scheduler-round-robin-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-scheduler-round-robin-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-scheduler-round-robin-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-scheduler-round-robin-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-scheduler-round-robin-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-scheduler-round-robin-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-scheduler-round-robin-probe.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-scheduler-round-robin-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for scheduler-round-robin probe runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for scheduler-round-robin PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for scheduler-round-robin PVH artifact failed with exit code $LASTEXITCODE"
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
set `$first_id = 0
set `$second_id = 0
set `$first_run_after_first = 0
set `$second_run_after_first = 0
set `$first_run_after_second = 0
set `$second_run_after_second = 0
set `$first_run_after_third = 0
set `$second_run_after_third = 0
set `$first_budget_after_first = 0
set `$second_budget_after_second = 0
set `$first_budget_after_third = 0
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
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $firstTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $firstTaskPriority
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$first_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $secondTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $secondTaskPriority
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset) != 0
    set `$second_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerEnableOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset) >= 1 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset) == 0
    set `$first_run_after_first = *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
    set `$second_run_after_first = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset)
    set `$first_budget_after_first = *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset) >= 1 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset) >= 1
    set `$first_run_after_second = *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
    set `$second_run_after_second = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset)
    set `$second_budget_after_second = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetRemainingOffset)
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset) >= 2 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset) >= 1
    set `$first_run_after_third = *(unsigned int*)(0x$schedulerTasksAddress+$taskRunCountOffset)
    set `$second_run_after_third = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskRunCountOffset)
    set `$first_budget_after_third = *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
    set `$stage = 9
  end
  continue
end
printf "AFTER_SCHEDULER_ROUND_ROBIN\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$schedulerStateAddress+$schedulerDispatchCountOffset)
printf "POLICY=%u\n", *(unsigned char*)(0x$schedulerPolicyAddress)
printf "FIRST_ID=%u\n", `$first_id
printf "SECOND_ID=%u\n", `$second_id
printf "FIRST_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset)
printf "SECOND_STATE=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskStateOffset)
printf "FIRST_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskPriorityOffset)
printf "SECOND_PRIORITY=%u\n", *(unsigned char*)(0x$schedulerTasksAddress+$taskStride+$taskPriorityOffset)
printf "FIRST_BUDGET_TICKS=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetTicksOffset)
printf "SECOND_BUDGET_TICKS=%u\n", *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetTicksOffset)
printf "FIRST_RUN_AFTER_FIRST=%u\n", `$first_run_after_first
printf "SECOND_RUN_AFTER_FIRST=%u\n", `$second_run_after_first
printf "FIRST_RUN_AFTER_SECOND=%u\n", `$first_run_after_second
printf "SECOND_RUN_AFTER_SECOND=%u\n", `$second_run_after_second
printf "FIRST_RUN_AFTER_THIRD=%u\n", `$first_run_after_third
printf "SECOND_RUN_AFTER_THIRD=%u\n", `$second_run_after_third
printf "FIRST_BUDGET_AFTER_FIRST=%u\n", `$first_budget_after_first
printf "SECOND_BUDGET_AFTER_SECOND=%u\n", `$second_budget_after_second
printf "FIRST_BUDGET_AFTER_THIRD=%u\n", `$first_budget_after_third
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
    $hitAfter = $gdbOutput.Contains("AFTER_SCHEDULER_ROUND_ROBIN")
}
if (Test-Path $gdbStderr) {
    $gdbError = Get-Content -Path $gdbStderr -Raw
}

if ($timedOut) {
    throw "QEMU scheduler-round-robin probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

if (-not $hitStart -or -not $hitAfter) {
    throw "Scheduler-round-robin probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskCount = Extract-IntValue -Text $gdbOutput -Name "TASK_COUNT"
$dispatchCount = Extract-IntValue -Text $gdbOutput -Name "DISPATCH_COUNT"
$policy = Extract-IntValue -Text $gdbOutput -Name "POLICY"
$firstId = Extract-IntValue -Text $gdbOutput -Name "FIRST_ID"
$secondId = Extract-IntValue -Text $gdbOutput -Name "SECOND_ID"
$firstState = Extract-IntValue -Text $gdbOutput -Name "FIRST_STATE"
$secondState = Extract-IntValue -Text $gdbOutput -Name "SECOND_STATE"
$firstPriority = Extract-IntValue -Text $gdbOutput -Name "FIRST_PRIORITY"
$secondPriority = Extract-IntValue -Text $gdbOutput -Name "SECOND_PRIORITY"
$firstBudgetTicks = Extract-IntValue -Text $gdbOutput -Name "FIRST_BUDGET_TICKS"
$secondBudgetTicks = Extract-IntValue -Text $gdbOutput -Name "SECOND_BUDGET_TICKS"
$firstRunAfterFirst = Extract-IntValue -Text $gdbOutput -Name "FIRST_RUN_AFTER_FIRST"
$secondRunAfterFirst = Extract-IntValue -Text $gdbOutput -Name "SECOND_RUN_AFTER_FIRST"
$firstRunAfterSecond = Extract-IntValue -Text $gdbOutput -Name "FIRST_RUN_AFTER_SECOND"
$secondRunAfterSecond = Extract-IntValue -Text $gdbOutput -Name "SECOND_RUN_AFTER_SECOND"
$firstRunAfterThird = Extract-IntValue -Text $gdbOutput -Name "FIRST_RUN_AFTER_THIRD"
$secondRunAfterThird = Extract-IntValue -Text $gdbOutput -Name "SECOND_RUN_AFTER_THIRD"
$firstBudgetAfterFirst = Extract-IntValue -Text $gdbOutput -Name "FIRST_BUDGET_AFTER_FIRST"
$secondBudgetAfterSecond = Extract-IntValue -Text $gdbOutput -Name "SECOND_BUDGET_AFTER_SECOND"
$firstBudgetAfterThird = Extract-IntValue -Text $gdbOutput -Name "FIRST_BUDGET_AFTER_THIRD"

if ($ack -ne 6) { throw "Expected ACK=6, got $ack" }
if ($lastOpcode -ne $schedulerEnableOpcode) { throw "Expected LAST_OPCODE=$schedulerEnableOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($ticks -lt 8) { throw "Expected TICKS >= 8, got $ticks" }
if ($taskCount -ne 2) { throw "Expected TASK_COUNT=2, got $taskCount" }
if ($dispatchCount -lt 3) { throw "Expected DISPATCH_COUNT >= 3, got $dispatchCount" }
if ($policy -ne $schedulerRoundRobinPolicy) { throw "Expected POLICY=$schedulerRoundRobinPolicy, got $policy" }
if ($firstId -le 0) { throw "Expected FIRST_ID > 0, got $firstId" }
if ($secondId -le $firstId) { throw "Expected SECOND_ID > FIRST_ID, got FIRST_ID=$firstId SECOND_ID=$secondId" }
if ($firstState -ne $taskStateReady) { throw "Expected FIRST_STATE=$taskStateReady, got $firstState" }
if ($secondState -ne $taskStateReady) { throw "Expected SECOND_STATE=$taskStateReady, got $secondState" }
if ($firstPriority -ne $firstTaskPriority) { throw "Expected FIRST_PRIORITY=$firstTaskPriority, got $firstPriority" }
if ($secondPriority -ne $secondTaskPriority) { throw "Expected SECOND_PRIORITY=$secondTaskPriority, got $secondPriority" }
if ($firstBudgetTicks -ne $firstTaskBudget) { throw "Expected FIRST_BUDGET_TICKS=$firstTaskBudget, got $firstBudgetTicks" }
if ($secondBudgetTicks -ne $secondTaskBudget) { throw "Expected SECOND_BUDGET_TICKS=$secondTaskBudget, got $secondBudgetTicks" }
if ($firstRunAfterFirst -ne 1) { throw "Expected FIRST_RUN_AFTER_FIRST=1, got $firstRunAfterFirst" }
if ($secondRunAfterFirst -ne 0) { throw "Expected SECOND_RUN_AFTER_FIRST=0, got $secondRunAfterFirst" }
if ($firstRunAfterSecond -ne 1) { throw "Expected FIRST_RUN_AFTER_SECOND=1, got $firstRunAfterSecond" }
if ($secondRunAfterSecond -ne 1) { throw "Expected SECOND_RUN_AFTER_SECOND=1, got $secondRunAfterSecond" }
if ($firstRunAfterThird -ne 2) { throw "Expected FIRST_RUN_AFTER_THIRD=2, got $firstRunAfterThird" }
if ($secondRunAfterThird -ne 1) { throw "Expected SECOND_RUN_AFTER_THIRD=1, got $secondRunAfterThird" }
if ($firstBudgetAfterFirst -ne 3) { throw "Expected FIRST_BUDGET_AFTER_FIRST=3, got $firstBudgetAfterFirst" }
if ($secondBudgetAfterSecond -ne 3) { throw "Expected SECOND_BUDGET_AFTER_SECOND=3, got $secondBudgetAfterSecond" }
if ($firstBudgetAfterThird -ne 2) { throw "Expected FIRST_BUDGET_AFTER_THIRD=2, got $firstBudgetAfterThird" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_PROBE=pass"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_ACK=$ack"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_TASK_COUNT=$taskCount"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_DISPATCH_COUNT=$dispatchCount"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_POLICY=$policy"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_ID=$firstId"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_ID=$secondId"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_STATE=$firstState"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_STATE=$secondState"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_PRIORITY=$firstPriority"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_PRIORITY=$secondPriority"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_BUDGET_TICKS=$firstBudgetTicks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_BUDGET_TICKS=$secondBudgetTicks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_RUN_AFTER_FIRST=$firstRunAfterFirst"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_RUN_AFTER_FIRST=$secondRunAfterFirst"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_RUN_AFTER_SECOND=$firstRunAfterSecond"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_RUN_AFTER_SECOND=$secondRunAfterSecond"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_RUN_AFTER_THIRD=$firstRunAfterThird"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_RUN_AFTER_THIRD=$secondRunAfterThird"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_BUDGET_AFTER_FIRST=$firstBudgetAfterFirst"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_SECOND_BUDGET_AFTER_SECOND=$secondBudgetAfterSecond"
Write-Output "BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FIRST_BUDGET_AFTER_THIRD=$firstBudgetAfterThird"

