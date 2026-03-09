param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1291
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-scheduler-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-panic-wake-recovery-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-panic-wake-recovery-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-panic-wake-recovery-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-panic-wake-recovery-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-panic-wake-recovery-probe.qemu.stderr.log"

$schedulerResetOpcode = 26
$wakeQueueClearOpcode = 44
$resetInterruptCountersOpcode = 8
$schedulerDisableOpcode = 25
$schedulerEnableOpcode = 24
$taskCreateOpcode = 27
$taskWaitInterruptOpcode = 57
$taskWaitForOpcode = 53
$triggerPanicOpcode = 5
$triggerInterruptOpcode = 7
$setModeOpcode = 4
$setBootPhaseOpcode = 16

$interruptTaskBudget = 6
$interruptTaskPriority = 0
$timerTaskBudget = 7
$timerTaskPriority = 1
$timerDelay = 5
$interruptVector = 200
$waitInterruptAnyVector = 65535

$modeRunning = 1
$modePanicked = 255
$bootPhaseRuntime = 2
$bootPhasePanicked = 255
$schedulerNoSlot = 255
$taskStateReady = 1
$taskStateWaiting = 6
$wakeReasonTimer = 1
$wakeReasonInterrupt = 2

$statusModeOffset = 6
$statusTicksOffset = 8
$statusPanicCountOffset = 24
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$bootDiagPhaseOffset = 6

$schedulerEnabledOffset = 0
$schedulerTaskCountOffset = 1
$schedulerRunningSlotOffset = 2
$schedulerDispatchCountOffset = 8

$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4
$taskRunCountOffset = 8
$taskBudgetRemainingOffset = 16

$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerDispatchCountOffset = 8

$wakeEventStride = 32
$wakeEventTaskIdOffset = 4
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

function Invoke-SchedulerArtifactBuildIfNeeded {
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Panic-wake recovery prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) { throw "Prerequisite script not found: $prerequisiteScript" }
    $prereqOutput = & $prerequisiteScript 2>&1
    $prereqExitCode = $LASTEXITCODE
    if ($prereqExitCode -ne 0) {
        if ($null -ne $prereqOutput) { $prereqOutput | Write-Output }
        throw "Scheduler prerequisite failed with exit code $prereqExitCode"
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PROBE=skipped"
    exit 0
}

if (-not (Test-Path $artifact)) {
    Invoke-SchedulerArtifactBuildIfNeeded
} elseif (-not $SkipBuild) {
    Invoke-SchedulerArtifactBuildIfNeeded
}

if (-not (Test-Path $artifact)) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PROBE=skipped"
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
$schedulerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_state$' -SymbolName "baremetal_main.scheduler_state"
$schedulerTasksAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_tasks$' -SymbolName "baremetal_main.scheduler_tasks"
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName "baremetal_main.timer_state"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"
$bootDiagnosticsAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.boot_diagnostics$' -SymbolName "baremetal_main.boot_diagnostics"

$artifactForGdb = $artifact.Replace('\', '/')
foreach ($path in @($gdbStdout, $gdbStderr, $qemuStdout, $qemuStderr)) {
    if (Test-Path $path) { Remove-Item -Force $path }
}

$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $interrupt_task_id = 0
set $timer_task_id = 0
file __ARTIFACT__
handle SIGQUIT nostop noprint pass
target remote :__GDBPORT__
break *0x__START__
commands
silent
printf "HIT_START\n"
set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_RESET_OPCODE__
set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 1
set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
set $stage = 1
continue
end
break *0x__SPINPAUSE__
commands
silent
if $stage == 1
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __WAKE_QUEUE_CLEAR_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 2
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 2
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __RESET_INTERRUPT_COUNTERS_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 3
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 3
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_DISABLE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 4
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 4
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 5
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __INTERRUPT_TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __INTERRUPT_TASK_PRIORITY__
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 5 && *(unsigned int*)(0x__TASKS__+__TASK0_ID_OFFSET__) != 0
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 6
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __TIMER_TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __TIMER_TASK_PRIORITY__
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 6 && *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_ID_OFFSET__) != 0
    set $interrupt_task_id = *(unsigned int*)(0x__TASKS__+__TASK0_ID_OFFSET__)
    set $timer_task_id = *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_ID_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_WAIT_INTERRUPT_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 7
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $interrupt_task_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __WAIT_INTERRUPT_ANY_VECTOR__
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 7 && *(unsigned char*)(0x__TASKS__+__TASK0_STATE_OFFSET__) == __TASK_STATE_WAITING__
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_WAIT_FOR_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 8
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $timer_task_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __TIMER_DELAY__
    set $stage = 8
  end
  continue
end
if $stage == 8
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 8 && *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_STATE_OFFSET__) == __TASK_STATE_WAITING__ && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 0 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_ENABLE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 9
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 9
  end
  continue
end
if $stage == 9
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 9 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_ENABLED_OFFSET__) == 1 && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 0 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__) == __SCHEDULER_NO_SLOT__
    printf "PRE_PANIC_TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "PRE_PANIC_RUNNING_SLOT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__)
    printf "PRE_PANIC_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__)
    printf "PRE_PANIC_TASK0_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK0_STATE_OFFSET__)
    printf "PRE_PANIC_TASK1_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_STATE_OFFSET__)
    printf "PRE_PANIC_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TRIGGER_PANIC_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 10
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 10
  end
  continue
end
if $stage == 10
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 10 && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __TRIGGER_PANIC_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_PANICKED__ && *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_COUNT_OFFSET__) == 1 && *(unsigned char*)(0x__BOOT_DIAG__+__BOOT_DIAG_PHASE_OFFSET__) == __BOOT_PHASE_PANICKED__ && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 0 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__) == __SCHEDULER_NO_SLOT__
    printf "PANIC_FREEZE_LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "PANIC_FREEZE_LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "PANIC_FREEZE_MODE=%u\n", *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    printf "PANIC_FREEZE_BOOT_PHASE=%u\n", *(unsigned char*)(0x__BOOT_DIAG__+__BOOT_DIAG_PHASE_OFFSET__)
    printf "PANIC_FREEZE_PANIC_COUNT=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_COUNT_OFFSET__)
    printf "PANIC_FREEZE_TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "PANIC_FREEZE_RUNNING_SLOT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__)
    printf "PANIC_FREEZE_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TRIGGER_INTERRUPT_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 11
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __INTERRUPT_VECTOR__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 11
  end
  continue
end
if $stage == 11
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 11 && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 1 && *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE_EVENT_TASK_ID_OFFSET__) == $interrupt_task_id && *(unsigned char*)(0x__WAKE_QUEUE__+__WAKE_EVENT_REASON_OFFSET__) == __WAKE_REASON_INTERRUPT__ && *(unsigned char*)(0x__WAKE_QUEUE__+__WAKE_EVENT_VECTOR_OFFSET__) == __INTERRUPT_VECTOR__ && *(unsigned char*)(0x__TASKS__+__TASK0_STATE_OFFSET__) == __TASK_STATE_READY__ && *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_STATE_OFFSET__) == __TASK_STATE_WAITING__ && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 1 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 1 && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 0
    printf "PANIC_WAKE1_TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "PANIC_WAKE1_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__)
    printf "PANIC_WAKE1_QUEUE_LEN=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "PANIC_WAKE1_TASK0_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK0_STATE_OFFSET__)
    printf "PANIC_WAKE1_TASK1_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_STATE_OFFSET__)
    printf "PANIC_WAKE1_REASON=%u\n", *(unsigned char*)(0x__WAKE_QUEUE__+__WAKE_EVENT_REASON_OFFSET__)
    printf "PANIC_WAKE1_VECTOR=%u\n", *(unsigned char*)(0x__WAKE_QUEUE__+__WAKE_EVENT_VECTOR_OFFSET__)
    set $stage = 12
  end
  continue
end
if $stage == 12
  if *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 2 && *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE_EVENT_STRIDE__+__WAKE_EVENT_TASK_ID_OFFSET__) == $timer_task_id && *(unsigned char*)(0x__WAKE_QUEUE__+__WAKE_EVENT_STRIDE__+__WAKE_EVENT_REASON_OFFSET__) == __WAKE_REASON_TIMER__ && *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_STATE_OFFSET__) == __TASK_STATE_READY__ && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 2 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__) == 2 && *(unsigned long long*)(0x__TIMER_STATE__+__TIMER_DISPATCH_COUNT_OFFSET__) >= 1 && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 0
    printf "PANIC_WAKE2_TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "PANIC_WAKE2_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__)
    printf "PANIC_WAKE2_QUEUE_LEN=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "PANIC_WAKE2_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    printf "PANIC_WAKE2_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__)
    printf "PANIC_WAKE2_REASON=%u\n", *(unsigned char*)(0x__WAKE_QUEUE__+__WAKE_EVENT_STRIDE__+__WAKE_EVENT_REASON_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_MODE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 12
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __MODE_RUNNING__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 13
  end
  continue
end
if $stage == 13
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 12 && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __SET_MODE_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_RUNNING__ && *(unsigned char*)(0x__BOOT_DIAG__+__BOOT_DIAG_PHASE_OFFSET__) == __BOOT_PHASE_PANICKED__ && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 1 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__) == 0 && *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_REMAINING_OFFSET__) == 5 && *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_RUN_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_BUDGET_REMAINING_OFFSET__) == 7
    printf "RECOVER1_MODE=%u\n", *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    printf "RECOVER1_BOOT_PHASE=%u\n", *(unsigned char*)(0x__BOOT_DIAG__+__BOOT_DIAG_PHASE_OFFSET__)
    printf "RECOVER1_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__)
    printf "RECOVER1_RUNNING_SLOT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__)
    printf "RECOVER1_TASK0_RUN_COUNT=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__)
    printf "RECOVER1_TASK0_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_REMAINING_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SET_BOOT_PHASE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 13
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __BOOT_PHASE_RUNTIME__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 14
  end
  continue
end
if $stage == 14
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 13 && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __SET_BOOT_PHASE_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__) == __MODE_RUNNING__ && *(unsigned char*)(0x__BOOT_DIAG__+__BOOT_DIAG_PHASE_OFFSET__) == __BOOT_PHASE_RUNTIME__ && *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_COUNT_OFFSET__) == 1 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 2 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__) == 1 && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_RUN_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_BUDGET_REMAINING_OFFSET__) == 6
    printf "HIT_AFTER_PANIC_WAKE_RECOVERY_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "MODE=%u\n", *(unsigned char*)(0x__STATUS__+__STATUS_MODE_OFFSET__)
    printf "BOOT_PHASE=%u\n", *(unsigned char*)(0x__BOOT_DIAG__+__BOOT_DIAG_PHASE_OFFSET__)
    printf "PANIC_COUNT=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_PANIC_COUNT_OFFSET__)
    printf "TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "RUNNING_SLOT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__)
    printf "DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__)
    printf "TASK0_RUN_COUNT=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__)
    printf "TASK1_RUN_COUNT=%u\n", *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_RUN_COUNT_OFFSET__)
    printf "TASK1_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK0_BUDGET_REMAINING_OFFSET__)
    detach
    quit
  end
  continue
end
continue
end
continue
'@

$gdbContent = $gdbTemplate.
    Replace('__ARTIFACT__', $artifactForGdb).
    Replace('__GDBPORT__', [string]$GdbPort).
    Replace('__START__', $startAddress).
    Replace('__SPINPAUSE__', $spinPauseAddress).
    Replace('__STATUS__', $statusAddress).
    Replace('__STATUS_MODE_OFFSET__', [string]$statusModeOffset).
    Replace('__STATUS_TICKS_OFFSET__', [string]$statusTicksOffset).
    Replace('__STATUS_PANIC_COUNT_OFFSET__', [string]$statusPanicCountOffset).
    Replace('__STATUS_ACK_OFFSET__', [string]$statusCommandSeqAckOffset).
    Replace('__STATUS_LAST_OPCODE_OFFSET__', [string]$statusLastCommandOpcodeOffset).
    Replace('__STATUS_LAST_RESULT_OFFSET__', [string]$statusLastCommandResultOffset).
    Replace('__COMMAND_MAILBOX__', $commandMailboxAddress).
    Replace('__COMMAND_OPCODE_OFFSET__', [string]$commandOpcodeOffset).
    Replace('__COMMAND_SEQ_OFFSET__', [string]$commandSeqOffset).
    Replace('__COMMAND_ARG0_OFFSET__', [string]$commandArg0Offset).
    Replace('__COMMAND_ARG1_OFFSET__', [string]$commandArg1Offset).
    Replace('__BOOT_DIAG__', $bootDiagnosticsAddress).
    Replace('__BOOT_DIAG_PHASE_OFFSET__', [string]$bootDiagPhaseOffset).
    Replace('__SCHED_STATE__', $schedulerStateAddress).
    Replace('__TASKS__', $schedulerTasksAddress).
    Replace('__TIMER_STATE__', $timerStateAddress).
    Replace('__WAKE_QUEUE__', $wakeQueueAddress).
    Replace('__WAKE_QUEUE_COUNT__', $wakeQueueCountAddress).
    Replace('__SCHEDULER_RESET_OPCODE__', [string]$schedulerResetOpcode).
    Replace('__WAKE_QUEUE_CLEAR_OPCODE__', [string]$wakeQueueClearOpcode).
    Replace('__RESET_INTERRUPT_COUNTERS_OPCODE__', [string]$resetInterruptCountersOpcode).
    Replace('__SCHEDULER_DISABLE_OPCODE__', [string]$schedulerDisableOpcode).
    Replace('__SCHEDULER_ENABLE_OPCODE__', [string]$schedulerEnableOpcode).
    Replace('__TASK_CREATE_OPCODE__', [string]$taskCreateOpcode).
    Replace('__TASK_WAIT_INTERRUPT_OPCODE__', [string]$taskWaitInterruptOpcode).
    Replace('__TASK_WAIT_FOR_OPCODE__', [string]$taskWaitForOpcode).
    Replace('__TRIGGER_PANIC_OPCODE__', [string]$triggerPanicOpcode).
    Replace('__TRIGGER_INTERRUPT_OPCODE__', [string]$triggerInterruptOpcode).
    Replace('__SET_MODE_OPCODE__', [string]$setModeOpcode).
    Replace('__SET_BOOT_PHASE_OPCODE__', [string]$setBootPhaseOpcode).
    Replace('__INTERRUPT_TASK_BUDGET__', [string]$interruptTaskBudget).
    Replace('__INTERRUPT_TASK_PRIORITY__', [string]$interruptTaskPriority).
    Replace('__TIMER_TASK_BUDGET__', [string]$timerTaskBudget).
    Replace('__TIMER_TASK_PRIORITY__', [string]$timerTaskPriority).
    Replace('__TIMER_DELAY__', [string]$timerDelay).
    Replace('__INTERRUPT_VECTOR__', [string]$interruptVector).
    Replace('__WAIT_INTERRUPT_ANY_VECTOR__', [string]$waitInterruptAnyVector).
    Replace('__MODE_RUNNING__', [string]$modeRunning).
    Replace('__MODE_PANICKED__', [string]$modePanicked).
    Replace('__BOOT_PHASE_RUNTIME__', [string]$bootPhaseRuntime).
    Replace('__BOOT_PHASE_PANICKED__', [string]$bootPhasePanicked).
    Replace('__SCHEDULER_NO_SLOT__', [string]$schedulerNoSlot).
    Replace('__SCHED_ENABLED_OFFSET__', [string]$schedulerEnabledOffset).
    Replace('__SCHED_TASK_COUNT_OFFSET__', [string]$schedulerTaskCountOffset).
    Replace('__SCHED_RUNNING_SLOT_OFFSET__', [string]$schedulerRunningSlotOffset).
    Replace('__SCHED_DISPATCH_COUNT_OFFSET__', [string]$schedulerDispatchCountOffset).
    Replace('__TASK_STRIDE__', [string]$taskStride).
    Replace('__TASK0_ID_OFFSET__', [string]$taskIdOffset).
    Replace('__TASK0_STATE_OFFSET__', [string]$taskStateOffset).
    Replace('__TASK0_RUN_COUNT_OFFSET__', [string]$taskRunCountOffset).
    Replace('__TASK0_BUDGET_REMAINING_OFFSET__', [string]$taskBudgetRemainingOffset).
    Replace('__TIMER_ENTRY_COUNT_OFFSET__', [string]$timerEntryCountOffset).
    Replace('__TIMER_PENDING_WAKE_COUNT_OFFSET__', [string]$timerPendingWakeCountOffset).
    Replace('__TIMER_DISPATCH_COUNT_OFFSET__', [string]$timerDispatchCountOffset).
    Replace('__WAKE_EVENT_STRIDE__', [string]$wakeEventStride).
    Replace('__WAKE_EVENT_TASK_ID_OFFSET__', [string]$wakeEventTaskIdOffset).
    Replace('__WAKE_EVENT_REASON_OFFSET__', [string]$wakeEventReasonOffset).
    Replace('__WAKE_EVENT_VECTOR_OFFSET__', [string]$wakeEventVectorOffset).
    Replace('__TASK_STATE_READY__', [string]$taskStateReady).
    Replace('__TASK_STATE_WAITING__', [string]$taskStateWaiting).
    Replace('__WAKE_REASON_TIMER__', [string]$wakeReasonTimer).
    Replace('__WAKE_REASON_INTERRUPT__', [string]$wakeReasonInterrupt)

Set-Content -Path $gdbScript -Value $gdbContent -Encoding Ascii -NoNewline

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

$qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -PassThru
try {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        if ($qemuProcess.HasExited) {
            $stderrText = if (Test-Path $qemuStderr) { Get-Content $qemuStderr -Raw } else { "" }
            $stdoutText = if (Test-Path $qemuStdout) { Get-Content $qemuStdout -Raw } else { "" }
            throw "QEMU exited before GDB completed. stdout: $stdoutText stderr: $stderrText"
        }
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect('127.0.0.1', $GdbPort, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(100)) {
                $tcp.EndConnect($async)
                $tcp.Close()
                break
            }
            $tcp.Close()
        } catch {
        }
    } while ((Get-Date) -lt $deadline)

    if ((Get-Date) -ge $deadline) {
        throw "Timed out waiting for QEMU GDB server on port $GdbPort"
    }

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("--quiet", "--batch", "-x", $gdbScript) -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr -PassThru
    if (-not $gdbProcess.WaitForExit($TimeoutSeconds * 1000)) {
        try { $gdbProcess.Kill() } catch {}
        throw "Timed out waiting for GDB panic-wake recovery probe"
    }

    $stdoutText = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
    $stderrText = if (Test-Path $gdbStderr) { Get-Content $gdbStderr -Raw } else { "" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProcess.ExitCode)) { 0 } else { [int]$gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        throw "GDB panic-wake recovery probe failed with exit code $gdbExitCode. stdout: $stdoutText stderr: $stderrText"
    }

    foreach ($requiredMarker in @("HIT_START", "HIT_AFTER_PANIC_WAKE_RECOVERY_PROBE")) {
        if ($stdoutText -notmatch [regex]::Escape($requiredMarker)) {
            throw "Missing expected marker '$requiredMarker' in GDB panic-wake recovery probe output. stdout: $stdoutText stderr: $stderrText"
        }
    }
} finally {
    if ($qemuProcess -and -not $qemuProcess.HasExited) {
        try { $qemuProcess.Kill() } catch {}
        try { $qemuProcess.WaitForExit() } catch {}
    }
}

$stdoutText = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
$stderrText = if (Test-Path $gdbStderr) { Get-Content $gdbStderr -Raw } else { "" }
if ($stderrText -match "Failed to resolve symbol address") {
    throw "GDB panic-wake recovery probe symbol resolution failed: $stderrText"
}

$expected = @{
    "PRE_PANIC_TASK_COUNT" = 0
    "PRE_PANIC_RUNNING_SLOT" = $schedulerNoSlot
    "PRE_PANIC_DISPATCH_COUNT" = 0
    "PRE_PANIC_TASK0_STATE" = $taskStateWaiting
    "PRE_PANIC_TASK1_STATE" = $taskStateWaiting
    "PRE_PANIC_TIMER_COUNT" = 1
    "PANIC_FREEZE_LAST_OPCODE" = $triggerPanicOpcode
    "PANIC_FREEZE_LAST_RESULT" = 0
    "PANIC_FREEZE_MODE" = $modePanicked
    "PANIC_FREEZE_BOOT_PHASE" = $bootPhasePanicked
    "PANIC_FREEZE_PANIC_COUNT" = 1
    "PANIC_FREEZE_TASK_COUNT" = 0
    "PANIC_FREEZE_RUNNING_SLOT" = $schedulerNoSlot
    "PANIC_FREEZE_DISPATCH_COUNT" = 0
    "PANIC_WAKE1_TASK_COUNT" = 1
    "PANIC_WAKE1_DISPATCH_COUNT" = 0
    "PANIC_WAKE1_QUEUE_LEN" = 1
    "PANIC_WAKE1_TASK0_STATE" = $taskStateReady
    "PANIC_WAKE1_TASK1_STATE" = $taskStateWaiting
    "PANIC_WAKE1_REASON" = $wakeReasonInterrupt
    "PANIC_WAKE1_VECTOR" = $interruptVector
    "PANIC_WAKE2_TASK_COUNT" = 2
    "PANIC_WAKE2_DISPATCH_COUNT" = 0
    "PANIC_WAKE2_QUEUE_LEN" = 2
    "PANIC_WAKE2_TIMER_COUNT" = 0
    "PANIC_WAKE2_PENDING_WAKE_COUNT" = 2
    "PANIC_WAKE2_REASON" = $wakeReasonTimer
    "RECOVER1_MODE" = $modeRunning
    "RECOVER1_BOOT_PHASE" = $bootPhasePanicked
    "RECOVER1_DISPATCH_COUNT" = 1
    "RECOVER1_RUNNING_SLOT" = 0
    "RECOVER1_TASK0_RUN_COUNT" = 1
    "RECOVER1_TASK0_BUDGET_REMAINING" = 5
    "ACK" = 13
    "LAST_OPCODE" = $setBootPhaseOpcode
    "LAST_RESULT" = 0
    "MODE" = $modeRunning
    "BOOT_PHASE" = $bootPhaseRuntime
    "PANIC_COUNT" = 1
    "TASK_COUNT" = 2
    "RUNNING_SLOT" = 1
    "DISPATCH_COUNT" = 2
    "TASK0_RUN_COUNT" = 1
    "TASK1_RUN_COUNT" = 1
    "TASK1_BUDGET_REMAINING" = 6
}

foreach ($entry in $expected.GetEnumerator()) {
    $actual = Extract-IntValue -Text $stdoutText -Name $entry.Key
    if ($null -eq $actual) {
        throw "Missing expected output line '$($entry.Key)=...' in GDB panic-wake recovery probe output.`n$stdoutText"
    }
    if ($actual -ne [int64]$entry.Value) {
        throw "Unexpected value for $($entry.Key): expected $($entry.Value), got $actual.`n$stdoutText"
    }
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PANIC_WAKE_RECOVERY_PROBE=pass"
$stdoutText.TrimEnd()
