param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1267
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-descriptor-bootdiag-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-reset-counters-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-reset-counters-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-reset-counters-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-reset-counters-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-reset-counters-probe.qemu.stderr.log"

$setHealthCodeOpcode = 1
$resetCountersOpcode = 3
$setModeOpcode = 4
$triggerPanicFlagOpcode = 5
$triggerInterruptOpcode = 7
$triggerExceptionOpcode = 12
$setBootPhaseOpcode = 16
$taskCreateOpcode = 27
$allocatorAllocOpcode = 32
$syscallRegisterOpcode = 34
$timerScheduleOpcode = 42
$timerSetQuantumOpcode = 48
$taskWaitInterruptOpcode = 57

$modeRunning = 1
$bootPhaseRuntime = 2
$healthCode = 123
$featureFlagsValue = 2774181210
$tickBatchHintValue = 4
$taskBudget = 8
$taskPriority = 2
$allocatorAllocSize = 4096
$allocatorAlign = 4096
$syscallId = 9
$syscallToken = 48879
$timerQuantum = 3
$timerDelay = 20
$interruptVector = 200
$exceptionVector = 13
$exceptionCode = 51966

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

$interruptStateInterruptCountOffset = 16
$interruptStateExceptionCountOffset = 32
$interruptStateExceptionHistoryLenOffset = 48
$interruptStateInterruptHistoryLenOffset = 56

$commandHistorySeqOffset = 0
$commandHistoryOpcodeOffset = 4
$commandResultOkCountOffset = 0
$commandResultInvalidCountOffset = 4
$commandResultNotSupportedCountOffset = 8
$commandResultOtherErrorCountOffset = 12
$commandResultTotalCountOffset = 16
$commandResultLastResultOffset = 24
$commandResultLastOpcodeOffset = 28
$commandResultLastSeqOffset = 32

$healthHistoryCodeOffset = 4
$healthHistoryAckOffset = 16

$schedulerEnabledOffset = 0
$schedulerTaskCountOffset = 1
$schedulerTimesliceOffset = 24
$taskIdOffset = 0

$allocatorFreePagesOffset = 24
$allocatorAllocationCountOffset = 28
$allocatorBytesInUseOffset = 40

$syscallStateEnabledOffset = 0
$syscallStateEntryCountOffset = 1
$syscallStateDispatchCountOffset = 8

$timerEnabledOffset = 0
$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerDispatchCountOffset = 8
$timerQuantumOffset = 40

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

function Invoke-DescriptorArtifactBuildIfNeeded {
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Reset-counters prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) { throw "Prerequisite script not found: $prerequisiteScript" }
    $prereqOutput = & $prerequisiteScript 2>&1
    $prereqExitCode = $LASTEXITCODE
    if ($prereqExitCode -ne 0) {
        if ($null -ne $prereqOutput) { $prereqOutput | Write-Output }
        throw "Descriptor bootdiag prerequisite failed with exit code $prereqExitCode"
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_RESET_COUNTERS_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_RESET_COUNTERS_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_RESET_COUNTERS_PROBE=skipped"
    exit 0
}

if (-not (Test-Path $artifact)) {
    Invoke-DescriptorArtifactBuildIfNeeded
} elseif (-not $SkipBuild) {
    Invoke-DescriptorArtifactBuildIfNeeded
}

if (-not (Test-Path $artifact)) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_RESET_COUNTERS_PROBE=skipped"
    exit 0
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) {
    throw "Failed to resolve symbol table from $artifact using $nm"
}

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$statusAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.status$' -SymbolName "baremetal_main.status"
$commandMailboxAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_mailbox$' -SymbolName "baremetal_main.command_mailbox"
$commandHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history$' -SymbolName "baremetal_main.command_history"
$commandHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history_count$' -SymbolName "baremetal_main.command_history_count"
$healthHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history$' -SymbolName "baremetal_main.health_history"
$healthHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_count$' -SymbolName "baremetal_main.health_history_count"
$modeHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.mode_history_count$' -SymbolName "baremetal_main.mode_history_count"
$bootHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_phase_history_count$' -SymbolName "baremetal_main.boot_phase_history_count"
$commandResultCountersAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_result_counters$' -SymbolName "baremetal_main.command_result_counters"
$schedulerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_state$' -SymbolName "baremetal_main.scheduler_state"
$schedulerTasksAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_tasks$' -SymbolName "baremetal_main.scheduler_tasks"
$allocatorStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.allocator_state$' -SymbolName "baremetal_main.allocator_state"
$syscallStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.syscall_state$' -SymbolName "baremetal_main.syscall_state"
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName "baremetal_main.timer_state"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$interruptStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_state$' -SymbolName "baremetal.x86_bootstrap.interrupt_state"
$interruptVectorCountsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_vector_counts$' -SymbolName "baremetal.x86_bootstrap.interrupt_vector_counts"
$exceptionVectorCountsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.exception_vector_counts$' -SymbolName "baremetal.x86_bootstrap.exception_vector_counts"

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
if `$stage == 0
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setHealthCodeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $healthCode
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 1
  end
  continue
end
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1
    set *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset) = $featureFlagsValue
    set *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) = $tickBatchHintValue
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerPanicFlagOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setModeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $modeRunning
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setBootPhaseOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $bootPhaseRuntime
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $taskPriority
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5
    set `$task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $allocatorAllocOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $allocatorAllocSize
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $allocatorAlign
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $syscallRegisterOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $syscallId
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $syscallToken
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerSetQuantumOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $timerQuantum
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $timerScheduleOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $timerDelay
    set `$stage = 9
  end
  continue
end
if `$stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 9
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 10
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$task_id
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $interruptVector
    set `$stage = 10
  end
  continue
end
if `$stage == 10
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 10
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 11
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 11
  end
  continue
end
if `$stage == 11
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 11
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerExceptionOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 12
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $exceptionVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $exceptionCode
    set `$stage = 12
  end
  continue
end
if `$stage == 12
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 12
    printf "PRE_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "PRE_FEATURE_FLAGS=%u\n", *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset)
    printf "PRE_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "PRE_PANIC_COUNT=%u\n", *(unsigned int*)(0x$statusAddress+$statusPanicCountOffset)
    printf "PRE_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
    printf "PRE_EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset)
    printf "PRE_INTERRUPT_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset)
    printf "PRE_EXCEPTION_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset)
    printf "PRE_INTERRUPT_VECTOR_200=%llu\n", *(unsigned long long*)(0x$interruptVectorCountsAddress + (8 * $interruptVector))
    printf "PRE_EXCEPTION_VECTOR_13=%llu\n", *(unsigned long long*)(0x$exceptionVectorCountsAddress + (8 * $exceptionVector))
    printf "PRE_COMMAND_HISTORY_LEN=%u\n", *(unsigned int*)0x$commandHistoryCountAddress
    printf "PRE_HEALTH_HISTORY_LEN=%u\n", *(unsigned int*)0x$healthHistoryCountAddress
    printf "PRE_MODE_HISTORY_LEN=%u\n", *(unsigned int*)0x$modeHistoryCountAddress
    printf "PRE_BOOT_HISTORY_LEN=%u\n", *(unsigned int*)0x$bootHistoryCountAddress
    printf "PRE_COMMAND_RESULT_TOTAL=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultTotalCountOffset)
    printf "PRE_SCHEDULER_TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    printf "PRE_ALLOCATOR_ALLOCATION_COUNT=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorAllocationCountOffset)
    printf "PRE_ALLOCATOR_BYTES_IN_USE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorBytesInUseOffset)
    printf "PRE_SYSCALL_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$syscallStateAddress+$syscallStateEntryCountOffset)
    printf "PRE_TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    printf "PRE_TIMER_QUANTUM=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
    printf "PRE_WAKE_QUEUE_LEN=%u\n", *(unsigned int*)0x$wakeQueueCountAddress
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 13
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 13
  end
  continue
end
if `$stage == 13
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 13
    printf "POST_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "POST_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "POST_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "POST_TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "POST_MODE=%u\n", *(unsigned char*)(0x$statusAddress+$statusModeOffset)
    printf "POST_HEALTH_CODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastHealthCodeOffset)
    printf "POST_FEATURE_FLAGS=%u\n", *(unsigned int*)(0x$statusAddress+$statusFeatureFlagsOffset)
    printf "POST_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "POST_PANIC_COUNT=%u\n", *(unsigned int*)(0x$statusAddress+$statusPanicCountOffset)
    printf "POST_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
    printf "POST_EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset)
    printf "POST_INTERRUPT_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset)
    printf "POST_EXCEPTION_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset)
    printf "POST_INTERRUPT_VECTOR_200=%llu\n", *(unsigned long long*)(0x$interruptVectorCountsAddress + (8 * $interruptVector))
    printf "POST_EXCEPTION_VECTOR_13=%llu\n", *(unsigned long long*)(0x$exceptionVectorCountsAddress + (8 * $exceptionVector))
    printf "POST_COMMAND_HISTORY_LEN=%u\n", *(unsigned int*)0x$commandHistoryCountAddress
    printf "POST_COMMAND_HISTORY_FIRST_SEQ=%u\n", *(unsigned int*)(0x$commandHistoryAddress+$commandHistorySeqOffset)
    printf "POST_COMMAND_HISTORY_FIRST_OPCODE=%u\n", *(unsigned short*)(0x$commandHistoryAddress+$commandHistoryOpcodeOffset)
    printf "POST_HEALTH_HISTORY_LEN=%u\n", *(unsigned int*)0x$healthHistoryCountAddress
    printf "POST_HEALTH_HISTORY_FIRST_CODE=%u\n", *(unsigned short*)(0x$healthHistoryAddress+$healthHistoryCodeOffset)
    printf "POST_HEALTH_HISTORY_FIRST_ACK=%u\n", *(unsigned int*)(0x$healthHistoryAddress+$healthHistoryAckOffset)
    printf "POST_MODE_HISTORY_LEN=%u\n", *(unsigned int*)0x$modeHistoryCountAddress
    printf "POST_BOOT_HISTORY_LEN=%u\n", *(unsigned int*)0x$bootHistoryCountAddress
    printf "POST_COMMAND_RESULT_OK=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOkCountOffset)
    printf "POST_COMMAND_RESULT_INVALID=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultInvalidCountOffset)
    printf "POST_COMMAND_RESULT_NOT_SUPPORTED=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultNotSupportedCountOffset)
    printf "POST_COMMAND_RESULT_OTHER=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultOtherErrorCountOffset)
    printf "POST_COMMAND_RESULT_TOTAL=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultTotalCountOffset)
    printf "POST_COMMAND_RESULT_LAST_RESULT=%d\n", *(short*)(0x$commandResultCountersAddress+$commandResultLastResultOffset)
    printf "POST_COMMAND_RESULT_LAST_OPCODE=%u\n", *(unsigned short*)(0x$commandResultCountersAddress+$commandResultLastOpcodeOffset)
    printf "POST_COMMAND_RESULT_LAST_SEQ=%u\n", *(unsigned int*)(0x$commandResultCountersAddress+$commandResultLastSeqOffset)
    printf "POST_SCHEDULER_ENABLED=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerEnabledOffset)
    printf "POST_SCHEDULER_TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    printf "POST_SCHEDULER_TIMESLICE=%u\n", *(unsigned int*)(0x$schedulerStateAddress+$schedulerTimesliceOffset)
    printf "POST_ALLOCATOR_FREE_PAGES=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorFreePagesOffset)
    printf "POST_ALLOCATOR_ALLOCATION_COUNT=%u\n", *(unsigned int*)(0x$allocatorStateAddress+$allocatorAllocationCountOffset)
    printf "POST_ALLOCATOR_BYTES_IN_USE=%llu\n", *(unsigned long long*)(0x$allocatorStateAddress+$allocatorBytesInUseOffset)
    printf "POST_SYSCALL_ENABLED=%u\n", *(unsigned char*)(0x$syscallStateAddress+$syscallStateEnabledOffset)
    printf "POST_SYSCALL_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$syscallStateAddress+$syscallStateEntryCountOffset)
    printf "POST_SYSCALL_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$syscallStateAddress+$syscallStateDispatchCountOffset)
    printf "POST_TIMER_ENABLED=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEnabledOffset)
    printf "POST_TIMER_ENTRY_COUNT=%u\n", *(unsigned char*)(0x$timerStateAddress+$timerEntryCountOffset)
    printf "POST_TIMER_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x$timerStateAddress+$timerPendingWakeCountOffset)
    printf "POST_TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x$timerStateAddress+$timerDispatchCountOffset)
    printf "POST_TIMER_QUANTUM=%u\n", *(unsigned int*)(0x$timerStateAddress+$timerQuantumOffset)
    printf "POST_WAKE_QUEUE_LEN=%u\n", *(unsigned int*)0x$wakeQueueCountAddress
    detach
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
    "-display", "none",
    "-no-reboot",
    "-no-shutdown",
    "-S",
    "-gdb", "tcp::$GdbPort"
)

$qemuProcess = $null
try {
    $qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
    Start-Sleep -Milliseconds 500

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("-q", "-x", $gdbScript) -PassThru -Wait -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr
    $gdbExitCode = $gdbProcess.ExitCode
    $gdbText = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
    if ($gdbExitCode -ne 0) {
        if ($gdbText) { $gdbText | Write-Output }
        throw "GDB probe failed with exit code $gdbExitCode"
    }

    $preAck = Extract-IntValue -Text $gdbText -Name "PRE_ACK"
    $preFeatureFlags = Extract-IntValue -Text $gdbText -Name "PRE_FEATURE_FLAGS"
    $preTickBatchHint = Extract-IntValue -Text $gdbText -Name "PRE_TICK_BATCH_HINT"
    $prePanicCount = Extract-IntValue -Text $gdbText -Name "PRE_PANIC_COUNT"
    $preInterruptCount = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT_COUNT"
    $preExceptionCount = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION_COUNT"
    $preInterruptHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT_HISTORY_LEN"
    $preExceptionHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION_HISTORY_LEN"
    $preInterruptVector = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT_VECTOR_200"
    $preExceptionVector = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION_VECTOR_13"
    $preCommandHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_COMMAND_HISTORY_LEN"
    $preHealthHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_HEALTH_HISTORY_LEN"
    $preModeHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_MODE_HISTORY_LEN"
    $preBootHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_BOOT_HISTORY_LEN"
    $preCommandResultTotal = Extract-IntValue -Text $gdbText -Name "PRE_COMMAND_RESULT_TOTAL"
    $preSchedulerTaskCount = Extract-IntValue -Text $gdbText -Name "PRE_SCHEDULER_TASK_COUNT"
    $preAllocatorAllocationCount = Extract-IntValue -Text $gdbText -Name "PRE_ALLOCATOR_ALLOCATION_COUNT"
    $preAllocatorBytesInUse = Extract-IntValue -Text $gdbText -Name "PRE_ALLOCATOR_BYTES_IN_USE"
    $preSyscallEntryCount = Extract-IntValue -Text $gdbText -Name "PRE_SYSCALL_ENTRY_COUNT"
    $preTimerEntryCount = Extract-IntValue -Text $gdbText -Name "PRE_TIMER_ENTRY_COUNT"
    $preTimerQuantum = Extract-IntValue -Text $gdbText -Name "PRE_TIMER_QUANTUM"
    $preWakeQueueLen = Extract-IntValue -Text $gdbText -Name "PRE_WAKE_QUEUE_LEN"

    $postAck = Extract-IntValue -Text $gdbText -Name "POST_ACK"
    $postLastOpcode = Extract-IntValue -Text $gdbText -Name "POST_LAST_OPCODE"
    $postLastResult = Extract-IntValue -Text $gdbText -Name "POST_LAST_RESULT"
    $postTicks = Extract-IntValue -Text $gdbText -Name "POST_TICKS"
    $postMode = Extract-IntValue -Text $gdbText -Name "POST_MODE"
    $postHealthCode = Extract-IntValue -Text $gdbText -Name "POST_HEALTH_CODE"
    $postFeatureFlags = Extract-IntValue -Text $gdbText -Name "POST_FEATURE_FLAGS"
    $postTickBatchHint = Extract-IntValue -Text $gdbText -Name "POST_TICK_BATCH_HINT"
    $postPanicCount = Extract-IntValue -Text $gdbText -Name "POST_PANIC_COUNT"
    $postInterruptCount = Extract-IntValue -Text $gdbText -Name "POST_INTERRUPT_COUNT"
    $postExceptionCount = Extract-IntValue -Text $gdbText -Name "POST_EXCEPTION_COUNT"
    $postInterruptHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_INTERRUPT_HISTORY_LEN"
    $postExceptionHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_EXCEPTION_HISTORY_LEN"
    $postInterruptVector = Extract-IntValue -Text $gdbText -Name "POST_INTERRUPT_VECTOR_200"
    $postExceptionVector = Extract-IntValue -Text $gdbText -Name "POST_EXCEPTION_VECTOR_13"
    $postCommandHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_HISTORY_LEN"
    $postCommandHistoryFirstSeq = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_HISTORY_FIRST_SEQ"
    $postCommandHistoryFirstOpcode = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_HISTORY_FIRST_OPCODE"
    $postHealthHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_HEALTH_HISTORY_LEN"
    $postHealthHistoryFirstCode = Extract-IntValue -Text $gdbText -Name "POST_HEALTH_HISTORY_FIRST_CODE"
    $postHealthHistoryFirstAck = Extract-IntValue -Text $gdbText -Name "POST_HEALTH_HISTORY_FIRST_ACK"
    $postModeHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_MODE_HISTORY_LEN"
    $postBootHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_BOOT_HISTORY_LEN"
    $postCommandResultOk = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_OK"
    $postCommandResultInvalid = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_INVALID"
    $postCommandResultNotSupported = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_NOT_SUPPORTED"
    $postCommandResultOther = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_OTHER"
    $postCommandResultTotal = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_TOTAL"
    $postCommandResultLastResult = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_LAST_RESULT"
    $postCommandResultLastOpcode = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_LAST_OPCODE"
    $postCommandResultLastSeq = Extract-IntValue -Text $gdbText -Name "POST_COMMAND_RESULT_LAST_SEQ"
    $postSchedulerEnabled = Extract-IntValue -Text $gdbText -Name "POST_SCHEDULER_ENABLED"
    $postSchedulerTaskCount = Extract-IntValue -Text $gdbText -Name "POST_SCHEDULER_TASK_COUNT"
    $postSchedulerTimeslice = Extract-IntValue -Text $gdbText -Name "POST_SCHEDULER_TIMESLICE"
    $postAllocatorFreePages = Extract-IntValue -Text $gdbText -Name "POST_ALLOCATOR_FREE_PAGES"
    $postAllocatorAllocationCount = Extract-IntValue -Text $gdbText -Name "POST_ALLOCATOR_ALLOCATION_COUNT"
    $postAllocatorBytesInUse = Extract-IntValue -Text $gdbText -Name "POST_ALLOCATOR_BYTES_IN_USE"
    $postSyscallEnabled = Extract-IntValue -Text $gdbText -Name "POST_SYSCALL_ENABLED"
    $postSyscallEntryCount = Extract-IntValue -Text $gdbText -Name "POST_SYSCALL_ENTRY_COUNT"
    $postSyscallDispatchCount = Extract-IntValue -Text $gdbText -Name "POST_SYSCALL_DISPATCH_COUNT"
    $postTimerEnabled = Extract-IntValue -Text $gdbText -Name "POST_TIMER_ENABLED"
    $postTimerEntryCount = Extract-IntValue -Text $gdbText -Name "POST_TIMER_ENTRY_COUNT"
    $postTimerPendingWakeCount = Extract-IntValue -Text $gdbText -Name "POST_TIMER_PENDING_WAKE_COUNT"
    $postTimerDispatchCount = Extract-IntValue -Text $gdbText -Name "POST_TIMER_DISPATCH_COUNT"
    $postTimerQuantum = Extract-IntValue -Text $gdbText -Name "POST_TIMER_QUANTUM"
    $postWakeQueueLen = Extract-IntValue -Text $gdbText -Name "POST_WAKE_QUEUE_LEN"

    $pass = (
        $preAck -eq 12 -and $preFeatureFlags -eq $featureFlagsValue -and $preTickBatchHint -eq $tickBatchHintValue -and
        $prePanicCount -eq 1 -and $preInterruptCount -ge 1 -and $preExceptionCount -ge 1 -and
        $preInterruptHistoryLen -ge 2 -and $preExceptionHistoryLen -ge 1 -and $preInterruptVector -eq 1 -and $preExceptionVector -eq 1 -and
        $preCommandHistoryLen -ge 12 -and $preHealthHistoryLen -ge 12 -and $preModeHistoryLen -ge 2 -and $preBootHistoryLen -ge 2 -and
        $preCommandResultTotal -ge 12 -and $preSchedulerTaskCount -eq 1 -and $preAllocatorAllocationCount -eq 1 -and $preAllocatorBytesInUse -eq $allocatorAllocSize -and
        $preSyscallEntryCount -eq 1 -and $preTimerEntryCount -eq 1 -and $preTimerQuantum -eq $timerQuantum -and $preWakeQueueLen -eq 1 -and
        $postAck -eq 13 -and $postLastOpcode -eq $resetCountersOpcode -and $postLastResult -eq 0 -and $postTicks -eq $tickBatchHintValue -and $postMode -eq $modeRunning -and
        $postHealthCode -eq 200 -and $postFeatureFlags -eq $featureFlagsValue -and $postTickBatchHint -eq $tickBatchHintValue -and $postPanicCount -eq 0 -and $postInterruptCount -eq 0 -and $postExceptionCount -eq 0 -and
        $postInterruptHistoryLen -eq 0 -and $postExceptionHistoryLen -eq 0 -and $postInterruptVector -eq 0 -and $postExceptionVector -eq 0 -and
        $postCommandHistoryLen -eq 1 -and $postCommandHistoryFirstSeq -eq 13 -and $postCommandHistoryFirstOpcode -eq $resetCountersOpcode -and
        $postHealthHistoryLen -eq 1 -and $postHealthHistoryFirstCode -eq 200 -and $postHealthHistoryFirstAck -eq 13 -and
        $postModeHistoryLen -eq 0 -and $postBootHistoryLen -eq 0 -and
        $postCommandResultOk -eq 1 -and $postCommandResultInvalid -eq 0 -and $postCommandResultNotSupported -eq 0 -and $postCommandResultOther -eq 0 -and
        $postCommandResultTotal -eq 1 -and $postCommandResultLastResult -eq 0 -and $postCommandResultLastOpcode -eq $resetCountersOpcode -and $postCommandResultLastSeq -eq 13 -and
        $postSchedulerEnabled -eq 0 -and $postSchedulerTaskCount -eq 0 -and $postSchedulerTimeslice -eq 1 -and
        $postAllocatorFreePages -eq 256 -and $postAllocatorAllocationCount -eq 0 -and $postAllocatorBytesInUse -eq 0 -and
        $postSyscallEnabled -eq 1 -and $postSyscallEntryCount -eq 0 -and $postSyscallDispatchCount -eq 0 -and
        $postTimerEnabled -eq 1 -and $postTimerEntryCount -eq 0 -and $postTimerPendingWakeCount -eq 0 -and $postTimerDispatchCount -eq 0 -and $postTimerQuantum -eq 1 -and
        $postWakeQueueLen -eq 0
    )

    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_RESET_COUNTERS_PROBE=$(if ($pass) { 'pass' } else { 'fail' })"
    $gdbText.TrimEnd() | Write-Output
    if (-not $pass) { exit 1 }
}
finally {
    if ($null -ne $qemuProcess -and -not $qemuProcess.HasExited) {
        Stop-Process -Id $qemuProcess.Id -Force
        $qemuProcess.WaitForExit()
    }
}


