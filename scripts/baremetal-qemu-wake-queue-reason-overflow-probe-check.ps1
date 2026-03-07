param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90,
    [int] $GdbPort = 1258
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-batch-pop-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-wake-queue-batch-pop.elf"
$gdbScript = Join-Path $releaseDir "qemu-wake-queue-reason-overflow-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-wake-queue-reason-overflow-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-wake-queue-reason-overflow-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-wake-queue-reason-overflow-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-wake-queue-reason-overflow-probe.qemu.stderr.log"

$schedulerResetOpcode = 26
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskWaitOpcode = 50
$taskWaitInterruptOpcode = 57
$schedulerWakeTaskOpcode = 45
$triggerInterruptOpcode = 7
$wakeQueuePopReasonOpcode = 59

$taskBudget = 5
$expectedTaskPriority = 0
$wakeQueueCapacity = 64
$overflowCycles = 66
$expectedOverflow = 2
$interruptVector = 13
$waitInterruptAnyVector = 65535
$resultOk = 0
$modeRunning = 1
$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonInterrupt = 2
$wakeReasonManual = 3
$expectedFinalAck = 139
$expectedFinalTickFloor = 139

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
$taskIdOffset = 0
$taskStateOffset = 4
$wakeEventStride = 32
$wakeEventSeqOffset = 0
$wakeEventReasonOffset = 12
$wakeEventVectorOffset = 13

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

function Invoke-BatchPopArtifactBuildIfNeeded {
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Wake-queue reason-overflow prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) { throw "Prerequisite script not found: $prerequisiteScript" }
    $prereqOutput = & $prerequisiteScript 2>&1
    $prereqExitCode = $LASTEXITCODE
    if ($prereqExitCode -ne 0) {
        if ($null -ne $prereqOutput) { $prereqOutput | Write-Output }
        throw "Wake-queue batch-pop prerequisite failed with exit code $prereqExitCode"
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_OVERFLOW_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_OVERFLOW_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_OVERFLOW_PROBE=skipped"
    exit 0
}

if (-not (Test-Path $artifact)) {
    Invoke-BatchPopArtifactBuildIfNeeded
} elseif (-not $SkipBuild) {
    Invoke-BatchPopArtifactBuildIfNeeded
}

if (-not (Test-Path $artifact)) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_OVERFLOW_PROBE=skipped"
    exit 0
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
$wakeQueueHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_head$' -SymbolName 'baremetal_main.wake_queue_head'
$wakeQueueTailAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_tail$' -SymbolName 'baremetal_main.wake_queue_tail'
$wakeQueueOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_overflow$' -SymbolName 'baremetal_main.wake_queue_overflow'
$artifactForGdb = $artifact.Replace('\', '/')

@"
set pagination off
set confirm off
set `$_stage = 0
set `$_expected_seq = 0
set `$_task_id = 0
set `$_wake_cycles = 0
set `$_current_reason = 0
set `$_pre_count = 0
set `$_pre_head = 0
set `$_pre_tail = 0
set `$_pre_overflow = 0
set `$_pre_first_seq = 0
set `$_pre_first_reason = 0
set `$_pre_last_seq = 0
set `$_pre_last_reason = 0
set `$_post_manual_count = 0
set `$_post_manual_head = 0
set `$_post_manual_tail = 0
set `$_post_manual_overflow = 0
set `$_post_manual_first_seq = 0
set `$_post_manual_first_reason = 0
set `$_post_manual_remaining_seq = 0
set `$_post_manual_remaining_reason = 0
set `$_post_manual_last_seq = 0
set `$_post_manual_last_reason = 0
set `$_post_interrupt_count = 0
set `$_post_interrupt_head = 0
set `$_post_interrupt_tail = 0
set `$_post_interrupt_overflow = 0
set `$_post_interrupt_first_seq = 0
set `$_post_interrupt_first_reason = 0
set `$_post_interrupt_last_seq = 0
set `$_post_interrupt_last_reason = 0
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
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $taskBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $expectedTaskPriority
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 5
  end
  continue
end
if `$_stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$_task_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    if (`$_wake_cycles & 1) == 0
      set `$_current_reason = $wakeReasonManual
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    else
      set `$_current_reason = $wakeReasonInterrupt
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $waitInterruptAnyVector
    end
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 6
  end
  continue
end
if `$_stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateWaiting
    if `$_current_reason == $wakeReasonManual
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerWakeTaskOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    else
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    end
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 7
  end
  continue
end
if `$_stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned char*)(0x$schedulerTasksAddress+$taskStateOffset) == $taskStateReady
    set `$_wake_cycles = (`$_wake_cycles + 1)
    if `$_wake_cycles == $overflowCycles && *(unsigned int*)0x$wakeQueueCountAddress == $wakeQueueCapacity && *(unsigned int*)0x$wakeQueueOverflowAddress == $expectedOverflow
      set `$_pre_count = *(unsigned int*)0x$wakeQueueCountAddress
      set `$_pre_head = *(unsigned int*)0x$wakeQueueHeadAddress
      set `$_pre_tail = *(unsigned int*)0x$wakeQueueTailAddress
      set `$_pre_overflow = *(unsigned int*)0x$wakeQueueOverflowAddress
      set `$_pre_first_seq = *(unsigned int*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventSeqOffset)
      set `$_pre_first_reason = *(unsigned char*)(0x$wakeQueueAddress + (2 * $wakeEventStride) + $wakeEventReasonOffset)
      set `$_pre_last_seq = *(unsigned int*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventSeqOffset)
      set `$_pre_last_reason = *(unsigned char*)(0x$wakeQueueAddress + (1 * $wakeEventStride) + $wakeEventReasonOffset)
      set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopReasonOpcode
      set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $wakeReasonManual
      set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 31
      set `$_expected_seq = (`$_expected_seq + 1)
      set `$_stage = 8
    else
      if (`$_wake_cycles & 1) == 0
        set `$_current_reason = $wakeReasonManual
        set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitOpcode
        set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
        set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
        set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
      else
        set `$_current_reason = $wakeReasonInterrupt
        set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskWaitInterruptOpcode
        set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
        set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = `$_task_id
        set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $waitInterruptAnyVector
      end
      set `$_expected_seq = (`$_expected_seq + 1)
      set `$_stage = 6
    end
  end
  continue
end
if `$_stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 33 && *(unsigned int*)0x$wakeQueueHeadAddress == 33 && *(unsigned int*)0x$wakeQueueTailAddress == 0
    set `$_post_manual_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_post_manual_head = *(unsigned int*)0x$wakeQueueHeadAddress
    set `$_post_manual_tail = *(unsigned int*)0x$wakeQueueTailAddress
    set `$_post_manual_overflow = *(unsigned int*)0x$wakeQueueOverflowAddress
    set `$_post_manual_first_seq = *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventSeqOffset)
    set `$_post_manual_first_reason = *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventReasonOffset)
    set `$_post_manual_remaining_seq = *(unsigned int*)(0x$wakeQueueAddress + (31 * $wakeEventStride) + $wakeEventSeqOffset)
    set `$_post_manual_remaining_reason = *(unsigned char*)(0x$wakeQueueAddress + (31 * $wakeEventStride) + $wakeEventReasonOffset)
    set `$_post_manual_last_seq = *(unsigned int*)(0x$wakeQueueAddress + (32 * $wakeEventStride) + $wakeEventSeqOffset)
    set `$_post_manual_last_reason = *(unsigned char*)(0x$wakeQueueAddress + (32 * $wakeEventStride) + $wakeEventReasonOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $wakeQueuePopReasonOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = (`$_expected_seq + 1)
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $wakeReasonManual
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 99
    set `$_expected_seq = (`$_expected_seq + 1)
    set `$_stage = 9
  end
  continue
end
if `$_stage == 9
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$_expected_seq && *(unsigned int*)0x$wakeQueueCountAddress == 32 && *(unsigned int*)0x$wakeQueueHeadAddress == 32 && *(unsigned int*)0x$wakeQueueTailAddress == 0
    set `$_post_interrupt_count = *(unsigned int*)0x$wakeQueueCountAddress
    set `$_post_interrupt_head = *(unsigned int*)0x$wakeQueueHeadAddress
    set `$_post_interrupt_tail = *(unsigned int*)0x$wakeQueueTailAddress
    set `$_post_interrupt_overflow = *(unsigned int*)0x$wakeQueueOverflowAddress
    set `$_post_interrupt_first_seq = *(unsigned int*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventSeqOffset)
    set `$_post_interrupt_first_reason = *(unsigned char*)(0x$wakeQueueAddress + (0 * $wakeEventStride) + $wakeEventReasonOffset)
    set `$_post_interrupt_last_seq = *(unsigned int*)(0x$wakeQueueAddress + (31 * $wakeEventStride) + $wakeEventSeqOffset)
    set `$_post_interrupt_last_reason = *(unsigned char*)(0x$wakeQueueAddress + (31 * $wakeEventStride) + $wakeEventReasonOffset)
    printf "AFTER_WAKE_QUEUE_REASON_OVERFLOW\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "TASK_ID=%u\n", `$_task_id
    printf "WAKE_CYCLES=%u\n", `$_wake_cycles
    printf "PRE_COUNT=%u\n", `$_pre_count
    printf "PRE_HEAD=%u\n", `$_pre_head
    printf "PRE_TAIL=%u\n", `$_pre_tail
    printf "PRE_OVERFLOW=%u\n", `$_pre_overflow
    printf "PRE_FIRST_SEQ=%u\n", `$_pre_first_seq
    printf "PRE_FIRST_REASON=%u\n", `$_pre_first_reason
    printf "PRE_LAST_SEQ=%u\n", `$_pre_last_seq
    printf "PRE_LAST_REASON=%u\n", `$_pre_last_reason
    printf "POST_MANUAL_COUNT=%u\n", `$_post_manual_count
    printf "POST_MANUAL_HEAD=%u\n", `$_post_manual_head
    printf "POST_MANUAL_TAIL=%u\n", `$_post_manual_tail
    printf "POST_MANUAL_OVERFLOW=%u\n", `$_post_manual_overflow
    printf "POST_MANUAL_FIRST_SEQ=%u\n", `$_post_manual_first_seq
    printf "POST_MANUAL_FIRST_REASON=%u\n", `$_post_manual_first_reason
    printf "POST_MANUAL_REMAINING_SEQ=%u\n", `$_post_manual_remaining_seq
    printf "POST_MANUAL_REMAINING_REASON=%u\n", `$_post_manual_remaining_reason
    printf "POST_MANUAL_LAST_SEQ=%u\n", `$_post_manual_last_seq
    printf "POST_MANUAL_LAST_REASON=%u\n", `$_post_manual_last_reason
    printf "POST_INTERRUPT_COUNT=%u\n", `$_post_interrupt_count
    printf "POST_INTERRUPT_HEAD=%u\n", `$_post_interrupt_head
    printf "POST_INTERRUPT_TAIL=%u\n", `$_post_interrupt_tail
    printf "POST_INTERRUPT_OVERFLOW=%u\n", `$_post_interrupt_overflow
    printf "POST_INTERRUPT_FIRST_SEQ=%u\n", `$_post_interrupt_first_seq
    printf "POST_INTERRUPT_FIRST_REASON=%u\n", `$_post_interrupt_first_reason
    printf "POST_INTERRUPT_LAST_SEQ=%u\n", `$_post_interrupt_last_seq
    printf "POST_INTERRUPT_LAST_REASON=%u\n", `$_post_interrupt_last_reason
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
    if ($null -eq $gdbOutput) { $gdbOutput = "" }
    $hitStart = $gdbOutput.Contains("HIT_START")
    $hitAfter = $gdbOutput.Contains("AFTER_WAKE_QUEUE_REASON_OVERFLOW")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
    if ($null -eq $gdbError) { $gdbError = "" }
}

if ($timedOut) { throw "QEMU Wake-queue reason-overflow probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError" }
$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) { throw "gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError" }
if (-not $hitStart -or -not $hitAfter) { throw "Wake-queue reason-overflow probe did not reach expected checkpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError" }

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
$taskId = Extract-IntValue -Text $gdbOutput -Name "TASK_ID"
$wakeCycles = Extract-IntValue -Text $gdbOutput -Name "WAKE_CYCLES"
$preCount = Extract-IntValue -Text $gdbOutput -Name "PRE_COUNT"
$preHead = Extract-IntValue -Text $gdbOutput -Name "PRE_HEAD"
$preTail = Extract-IntValue -Text $gdbOutput -Name "PRE_TAIL"
$preOverflow = Extract-IntValue -Text $gdbOutput -Name "PRE_OVERFLOW"
$preFirstSeq = Extract-IntValue -Text $gdbOutput -Name "PRE_FIRST_SEQ"
$preFirstReason = Extract-IntValue -Text $gdbOutput -Name "PRE_FIRST_REASON"
$preLastSeq = Extract-IntValue -Text $gdbOutput -Name "PRE_LAST_SEQ"
$preLastReason = Extract-IntValue -Text $gdbOutput -Name "PRE_LAST_REASON"
$postManualCount = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_COUNT"
$postManualHead = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_HEAD"
$postManualTail = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_TAIL"
$postManualOverflow = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_OVERFLOW"
$postManualFirstSeq = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_FIRST_SEQ"
$postManualFirstReason = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_FIRST_REASON"
$postManualRemainingSeq = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_REMAINING_SEQ"
$postManualRemainingReason = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_REMAINING_REASON"
$postManualLastSeq = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_LAST_SEQ"
$postManualLastReason = Extract-IntValue -Text $gdbOutput -Name "POST_MANUAL_LAST_REASON"
$postInterruptCount = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_COUNT"
$postInterruptHead = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_HEAD"
$postInterruptTail = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_TAIL"
$postInterruptOverflow = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_OVERFLOW"
$postInterruptFirstSeq = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_FIRST_SEQ"
$postInterruptFirstReason = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_FIRST_REASON"
$postInterruptLastSeq = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_LAST_SEQ"
$postInterruptLastReason = Extract-IntValue -Text $gdbOutput -Name "POST_INTERRUPT_LAST_REASON"

if ($ack -ne $expectedFinalAck) { throw "Expected ACK=$expectedFinalAck, got $ack" }
if ($lastOpcode -ne $wakeQueuePopReasonOpcode) { throw "Expected LAST_OPCODE=$wakeQueuePopReasonOpcode, got $lastOpcode" }
if ($lastResult -ne $resultOk) { throw "Expected LAST_RESULT=$resultOk, got $lastResult" }
if ($ticks -lt $expectedFinalTickFloor) { throw "Expected TICKS >= $expectedFinalTickFloor, got $ticks" }
if ($taskId -ne 1) { throw "Expected TASK_ID=1, got $taskId" }
if ($wakeCycles -ne $overflowCycles) { throw "Expected WAKE_CYCLES=$overflowCycles, got $wakeCycles" }
if ($preCount -ne $wakeQueueCapacity -or $preHead -ne 2 -or $preTail -ne 2 -or $preOverflow -ne $expectedOverflow) { throw "Unexpected PRE queue summary: $preCount/$preHead/$preTail/$preOverflow" }
if ($preFirstSeq -ne 3 -or $preFirstReason -ne $wakeReasonManual -or $preLastSeq -ne 66 -or $preLastReason -ne $wakeReasonInterrupt) { throw "Unexpected PRE seq/reason summary: $preFirstSeq/$preFirstReason/$preLastSeq/$preLastReason" }
if ($postManualCount -ne 33 -or $postManualHead -ne 33 -or $postManualTail -ne 0 -or $postManualOverflow -ne $expectedOverflow) { throw "Unexpected POST_MANUAL summary: $postManualCount/$postManualHead/$postManualTail/$postManualOverflow" }
if ($postManualFirstSeq -ne 4 -or $postManualFirstReason -ne $wakeReasonInterrupt -or $postManualRemainingSeq -ne 65 -or $postManualRemainingReason -ne $wakeReasonManual -or $postManualLastSeq -ne 66 -or $postManualLastReason -ne $wakeReasonInterrupt) { throw "Unexpected POST_MANUAL seq/reason summary" }
if ($postInterruptCount -ne 32 -or $postInterruptHead -ne 32 -or $postInterruptTail -ne 0 -or $postInterruptOverflow -ne $expectedOverflow) { throw "Unexpected POST_INTERRUPT summary: $postInterruptCount/$postInterruptHead/$postInterruptTail/$postInterruptOverflow" }
if ($postInterruptFirstSeq -ne 4 -or $postInterruptFirstReason -ne $wakeReasonInterrupt -or $postInterruptLastSeq -ne 66 -or $postInterruptLastReason -ne $wakeReasonInterrupt) { throw "Unexpected POST_INTERRUPT seq/reason summary" }

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_WAKE_QUEUE_REASON_OVERFLOW_PROBE=pass"
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TICKS=$ticks"
Write-Output "TASK_ID=$taskId"
Write-Output "WAKE_CYCLES=$wakeCycles"
Write-Output "PRE_COUNT=$preCount"
Write-Output "PRE_HEAD=$preHead"
Write-Output "PRE_TAIL=$preTail"
Write-Output "PRE_OVERFLOW=$preOverflow"
Write-Output "PRE_FIRST_SEQ=$preFirstSeq"
Write-Output "PRE_FIRST_REASON=$preFirstReason"
Write-Output "PRE_LAST_SEQ=$preLastSeq"
Write-Output "PRE_LAST_REASON=$preLastReason"
Write-Output "POST_MANUAL_COUNT=$postManualCount"
Write-Output "POST_MANUAL_HEAD=$postManualHead"
Write-Output "POST_MANUAL_TAIL=$postManualTail"
Write-Output "POST_MANUAL_OVERFLOW=$postManualOverflow"
Write-Output "POST_MANUAL_FIRST_SEQ=$postManualFirstSeq"
Write-Output "POST_MANUAL_FIRST_REASON=$postManualFirstReason"
Write-Output "POST_MANUAL_REMAINING_SEQ=$postManualRemainingSeq"
Write-Output "POST_MANUAL_REMAINING_REASON=$postManualRemainingReason"
Write-Output "POST_MANUAL_LAST_SEQ=$postManualLastSeq"
Write-Output "POST_MANUAL_LAST_REASON=$postManualLastReason"
Write-Output "POST_INTERRUPT_COUNT=$postInterruptCount"
Write-Output "POST_INTERRUPT_HEAD=$postInterruptHead"
Write-Output "POST_INTERRUPT_TAIL=$postInterruptTail"
Write-Output "POST_INTERRUPT_OVERFLOW=$postInterruptOverflow"
Write-Output "POST_INTERRUPT_FIRST_SEQ=$postInterruptFirstSeq"
Write-Output "POST_INTERRUPT_FIRST_REASON=$postInterruptFirstReason"
Write-Output "POST_INTERRUPT_LAST_SEQ=$postInterruptLastSeq"
Write-Output "POST_INTERRUPT_LAST_REASON=$postInterruptLastReason"
