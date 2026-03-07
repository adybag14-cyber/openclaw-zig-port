param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$schedulerResetOpcode = 26
$taskCreateOpcode = 27
$taskTerminateOpcode = 28

$taskCapacity = 16
$taskBudget = 2
$overflowTaskBudget = 3
$reuseTaskBudget = 7
$reuseTaskPriority = 99
$reuseSlotIndex = 5

$resultOk = 0
$resultNoSpace = -28
$taskStateReady = 1
$taskStateTerminated = 4
$modeRunning = 1

$statusModeOffset = 6
$statusTicksOffset = 8
$statusLastHealthCodeOffset = 16
$statusFeatureFlagsOffset = 20
$statusPanicCountOffset = 24
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
$taskPriorityOffset = 5
$taskBudgetTicksOffset = 12

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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_PROBE=skipped"
    return
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_PROBE=skipped"
    return
}

if ($GdbPort -le 0) {
    $GdbPort = Resolve-FreeTcpPort
}

$optionsPath = Join-Path $releaseDir "qemu-scheduler-saturation-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-scheduler-saturation.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-scheduler-saturation.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-scheduler-saturation.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-scheduler-saturation-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-scheduler-saturation-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-scheduler-saturation-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-scheduler-saturation-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-scheduler-saturation-$runStamp.qemu.stderr.log"

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
        --name "openclaw-zig-baremetal-main-scheduler-saturation" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for scheduler saturation runtime failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for scheduler saturation PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for scheduler saturation PVH artifact failed with exit code $LASTEXITCODE"
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
$artifactForGdb = $artifact.Replace('\', '/')
$reuseSlotAddressExpr = "0x$schedulerTasksAddress+$($reuseSlotIndex * $taskStride)"
$lastSlotAddressExpr = "0x$schedulerTasksAddress+$((($taskCapacity - 1) * $taskStride))"

@"
set pagination off
set confirm off
set `$_created = 0
set `$_full_count = 0
set `$_last_task_id = 0
set `$_reused_slot_previous_id = 0
set `$_reused_slot_new_id = 0
set `$_terminated_state = 0
set `$_stage = 0
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
    set *(unsigned short*)(0x$statusAddress+$statusLastHealthCodeOffset) = 200
    set *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusPanicCountOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset) = 0
    set *(short*)(0x$statusAddress+$statusLastCommandResultOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) = 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerResetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 1
  end
  continue
end
if `$_stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set `$_stage = 2
  end
  continue
end
if `$_stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == (1 + `$_created) && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == `$_created
    if `$_created < $taskCapacity
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (2 + `$_created)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = (`$_created + 1)
      set `$_created = (`$_created + 1)
    else
      set `$_full_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
      set `$_last_task_id = *(unsigned int*)($lastSlotAddressExpr+$taskIdOffset)
      set `$_reused_slot_previous_id = *(unsigned int*)($reuseSlotAddressExpr+$taskIdOffset)
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 18
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $overflowTaskBudget
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 77
      set `$_stage = 3
    end
  end
  continue
end
if `$_stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 18 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultNoSpace && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == $taskCapacity
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskTerminateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 19
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_reused_slot_previous_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$_stage = 4
  end
  continue
end
if `$_stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 19 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == ($taskCapacity - 1) && *(unsigned char*)($reuseSlotAddressExpr+$taskStateOffset) == $taskStateTerminated
    set `$_terminated_state = *(unsigned char*)($reuseSlotAddressExpr+$taskStateOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 20
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $reuseTaskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $reuseTaskPriority
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 20 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == $taskCapacity && *(unsigned char*)($reuseSlotAddressExpr+$taskStateOffset) == $taskStateReady && *(unsigned int*)($reuseSlotAddressExpr+$taskIdOffset) != `$_reused_slot_previous_id
    set `$_reused_slot_new_id = *(unsigned int*)($reuseSlotAddressExpr+$taskIdOffset)
    set `$_stage = 6
  end
  continue
end
printf "AFTER_SCHEDULER_SATURATION\n"
printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
printf "TASK_CAPACITY=%u\n", $taskCapacity
printf "TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
printf "FULL_COUNT=%u\n", `$_full_count
printf "LAST_TASK_ID=%u\n", `$_last_task_id
printf "REUSED_SLOT_PREVIOUS_ID=%u\n", `$_reused_slot_previous_id
printf "REUSED_SLOT_NEW_ID=%u\n", `$_reused_slot_new_id
printf "TERMINATED_STATE=%u\n", `$_terminated_state
printf "REUSED_STATE=%u\n", *(unsigned char*)($reuseSlotAddressExpr+$taskStateOffset)
printf "REUSED_PRIORITY=%u\n", *(unsigned char*)($reuseSlotAddressExpr+$taskPriorityOffset)
printf "REUSED_BUDGET_TICKS=%u\n", *(unsigned int*)($reuseSlotAddressExpr+$taskBudgetTicksOffset)
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
    $hitAfter = $gdbOutput.Contains("AFTER_SCHEDULER_SATURATION")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU scheduler saturation probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "Scheduler saturation probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskCapacityValue = Extract-IntValue -Text $gdbOutput -Name "TASK_CAPACITY"
$taskCount = Extract-IntValue -Text $gdbOutput -Name "TASK_COUNT"
$fullCount = Extract-IntValue -Text $gdbOutput -Name "FULL_COUNT"
$lastTaskId = Extract-IntValue -Text $gdbOutput -Name "LAST_TASK_ID"
$reusedSlotPreviousId = Extract-IntValue -Text $gdbOutput -Name "REUSED_SLOT_PREVIOUS_ID"
$reusedSlotNewId = Extract-IntValue -Text $gdbOutput -Name "REUSED_SLOT_NEW_ID"
$terminatedState = Extract-IntValue -Text $gdbOutput -Name "TERMINATED_STATE"
$reusedState = Extract-IntValue -Text $gdbOutput -Name "REUSED_STATE"
$reusedPriority = Extract-IntValue -Text $gdbOutput -Name "REUSED_PRIORITY"
$reusedBudgetTicks = Extract-IntValue -Text $gdbOutput -Name "REUSED_BUDGET_TICKS"

if ($ack -ne 20) { throw "Expected ACK=20, got $ack" }
if ($lastOpcode -ne $taskCreateOpcode) { throw "Expected LAST_OPCODE=$taskCreateOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($ticks -lt 20) { throw "Expected TICKS >= 20, got $ticks" }
if ($taskCapacityValue -ne $taskCapacity) { throw "Expected TASK_CAPACITY=$taskCapacity, got $taskCapacityValue" }
if ($fullCount -ne $taskCapacity) { throw "Expected FULL_COUNT=$taskCapacity, got $fullCount" }
if ($taskCount -ne $taskCapacity) { throw "Expected TASK_COUNT=$taskCapacity, got $taskCount" }
if ($lastTaskId -ne $taskCapacity) { throw "Expected LAST_TASK_ID=$taskCapacity, got $lastTaskId" }
if ($reusedSlotPreviousId -le 0) { throw "Expected REUSED_SLOT_PREVIOUS_ID > 0, got $reusedSlotPreviousId" }
if ($terminatedState -ne $taskStateTerminated) { throw "Expected TERMINATED_STATE=$taskStateTerminated, got $terminatedState" }
if ($reusedSlotNewId -le $lastTaskId) { throw "Expected REUSED_SLOT_NEW_ID > LAST_TASK_ID, got NEW=$reusedSlotNewId LAST=$lastTaskId" }
if ($reusedState -ne $taskStateReady) { throw "Expected REUSED_STATE=$taskStateReady, got $reusedState" }
if ($reusedPriority -ne $reuseTaskPriority) { throw "Expected REUSED_PRIORITY=$reuseTaskPriority, got $reusedPriority" }
if ($reusedBudgetTicks -ne $reuseTaskBudget) { throw "Expected REUSED_BUDGET_TICKS=$reuseTaskBudget, got $reusedBudgetTicks" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_STATUS_ADDR=0x$statusAddress"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_MAILBOX_ADDR=0x$commandMailboxAddress"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_ACK=$ack"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_TASK_CAPACITY=$taskCapacityValue"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_TASK_COUNT=$taskCount"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_FULL_COUNT=$fullCount"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_LAST_TASK_ID=$lastTaskId"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_REUSED_SLOT_PREVIOUS_ID=$reusedSlotPreviousId"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_REUSED_SLOT_NEW_ID=$reusedSlotNewId"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_TERMINATED_STATE=$terminatedState"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_REUSED_STATE=$reusedState"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_REUSED_PRIORITY=$reusedPriority"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_REUSED_BUDGET_TICKS=$reusedBudgetTicks"
Write-Output "BAREMETAL_QEMU_SCHEDULER_SATURATION_PROBE=pass"
