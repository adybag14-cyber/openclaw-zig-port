param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 1336
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-timer-reset-recovery-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-timer-reset-recovery.elf"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")
$gdbScript = Join-Path $releaseDir "qemu-task-terminate-mixed-state-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-task-terminate-mixed-state-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-task-terminate-mixed-state-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-task-terminate-mixed-state-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-task-terminate-mixed-state-probe-$runStamp.qemu.stderr.log"

$schedulerResetOpcode = 26
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$taskTerminateOpcode = 28
$taskWaitOpcode = 29
$timerSetQuantumOpcode = 48
$taskWaitForOpcode = 53
$schedulerWakeTaskOpcode = 45

$terminatedTaskBudget = 5
$terminatedTaskPriority = 1
$survivorTaskBudget = 6
$survivorTaskPriority = 2
$timerQuantum = 5
$timerDelay = 10
$idleTicksAfterTerminate = 20

$waitConditionNone = 0
$taskStateReady = 1
$taskStateTerminated = 4

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$schedulerTaskCountOffset = 1

$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4

$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerNextTimerIdOffset = 4
$timerDispatchCountOffset = 8
$timerQuantumOffset = 40

$timerEntryStride = 40
$timerEntryTimerIdOffset = 0
$timerEntryTaskIdOffset = 4
$timerEntryStateOffset = 8

$wakeEventStride = 32
$wakeEventSeqOffset = 0
$wakeEventTaskIdOffset = 4
$wakeEventTimerIdOffset = 8
$wakeEventReasonOffset = 12

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

function Invoke-ArtifactBuildIfNeeded {
    if ($SkipBuild -and -not (Test-Path $artifact)) {
        throw "Task-terminate mixed-state prerequisite artifact not found at $artifact and -SkipBuild was supplied."
    }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) { throw "Prerequisite script not found: $prerequisiteScript" }
    $prereqOutput = & $prerequisiteScript 2>&1
    $prereqExitCode = $LASTEXITCODE
    if ($prereqExitCode -ne 0) {
        if ($null -ne $prereqOutput) { $prereqOutput | Write-Output }
        throw "Task-terminate mixed-state prerequisite failed with exit code $prereqExitCode"
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_PROBE=skipped"
    exit 0
}

if (-not (Test-Path $artifact)) {
    Invoke-ArtifactBuildIfNeeded
} elseif (-not $SkipBuild) {
    Invoke-ArtifactBuildIfNeeded
}

if (-not (Test-Path $artifact)) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_PROBE=skipped"
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
$schedulerWaitKindAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_kind$' -SymbolName "baremetal_main.scheduler_wait_kind"
$schedulerWaitTimeoutAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_wait_timeout_tick$' -SymbolName "baremetal_main.scheduler_wait_timeout_tick"
$timerStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_state$' -SymbolName "baremetal_main.timer_state"
$timerEntriesAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.timer_entries$' -SymbolName "baremetal_main.timer_entries"
$wakeQueueAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue$' -SymbolName "baremetal_main.wake_queue"
$wakeQueueCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.wake_queue_count$' -SymbolName "baremetal_main.wake_queue_count"

$artifactForGdb = $artifact.Replace('\', '/')
foreach ($path in @($gdbStdout, $gdbStderr, $qemuStdout, $qemuStderr)) {
    if (Test-Path $path) { Remove-Item -Force $path }
}

$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
set $idle_start_ticks = 0
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
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_DISABLE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 2
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 2
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 3
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __TERMINATED_TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __TERMINATED_TASK_PRIORITY__
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 3 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 1
    set $task0_id = *(unsigned int*)(0x__TASKS__+__TASK_ID_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 4
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __SURVIVOR_TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __SURVIVOR_TASK_PRIORITY__
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 4 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 2
    set $task1_id = *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK_ID_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TIMER_SET_QUANTUM_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 5
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __TIMER_QUANTUM__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 5
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_WAIT_FOR_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 6
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task0_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __TIMER_DELAY__
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 6 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_WAKE_TASK_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 7
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task0_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 7 && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_WAIT_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 8
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task1_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 8
  end
  continue
end
if $stage == 8
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 8
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_WAKE_TASK_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 9
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task1_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 9
  end
  continue
end
if $stage == 9
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 9 && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 2 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__) == 2 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__) == __TIMER_QUANTUM__ && *(unsigned char*)(0x__TASKS__+__TASK_STATE_OFFSET__) == __TASK_STATE_READY__ && *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK_STATE_OFFSET__) == __TASK_STATE_READY__ && *(unsigned char*)(0x__WAIT_KIND__) == __WAIT_KIND_NONE__ && *(unsigned char*)(0x__WAIT_KIND__+1) == __WAIT_KIND_NONE__ && *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE0_TASK_ID_OFFSET__) == $task0_id && *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE1_TASK_ID_OFFSET__) == $task1_id && *(unsigned char*)(0x__TIMER_ENTRIES__+__TIMER_ENTRY_STATE_OFFSET__) == 3
    printf "PRE_TERMINATED_TASK_ID=%u\n", $task0_id
    printf "PRE_SURVIVOR_TASK_ID=%u\n", $task1_id
    printf "PRE_WAKE_COUNT=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "PRE_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__)
    printf "PRE_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    printf "PRE_NEXT_TIMER_ID=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__)
    printf "PRE_QUANTUM=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__)
    printf "PRE_WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE0_TASK_ID_OFFSET__)
    printf "PRE_WAKE1_TASK_ID=%u\n", *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE1_TASK_ID_OFFSET__)
    printf "PRE_TIMER0_STATE=%u\n", *(unsigned char*)(0x__TIMER_ENTRIES__+__TIMER_ENTRY_STATE_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_TERMINATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 10
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task0_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 10
  end
  continue
end
if $stage == 10
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 10 && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __TASK_TERMINATE_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == 0 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 1 && *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__) == 1 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__) == 2 && *(unsigned char*)(0x__TIMER_ENTRIES__+__TIMER_ENTRY_STATE_OFFSET__) == 3 && *(unsigned char*)(0x__TASKS__+__TASK_STATE_OFFSET__) == __TASK_STATE_TERMINATED__ && *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK_STATE_OFFSET__) == __TASK_STATE_READY__ && *(unsigned char*)(0x__WAIT_KIND__) == __WAIT_KIND_NONE__ && *(unsigned char*)(0x__WAIT_KIND__+1) == __WAIT_KIND_NONE__ && *(unsigned long long*)(0x__WAIT_TIMEOUT__) == 0 && *(unsigned long long*)(0x__WAIT_TIMEOUT__+8) == 0 && *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE0_TASK_ID_OFFSET__) == $task1_id
    printf "POST_TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "POST_WAKE_COUNT=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "POST_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__)
    printf "POST_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    printf "POST_NEXT_TIMER_ID=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__)
    printf "POST_QUANTUM=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__)
    printf "POST_TIMER0_STATE=%u\n", *(unsigned char*)(0x__TIMER_ENTRIES__+__TIMER_ENTRY_STATE_OFFSET__)
    printf "POST_TASK0_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK_STATE_OFFSET__)
    printf "POST_TASK1_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK_STATE_OFFSET__)
    printf "POST_WAIT_KIND0=%u\n", *(unsigned char*)(0x__WAIT_KIND__)
    printf "POST_WAIT_KIND1=%u\n", *(unsigned char*)(0x__WAIT_KIND__+1)
    printf "POST_WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x__WAIT_TIMEOUT__)
    printf "POST_WAIT_TIMEOUT1=%llu\n", *(unsigned long long*)(0x__WAIT_TIMEOUT__+8)
    printf "POST_WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE0_TASK_ID_OFFSET__)
    set $idle_start_ticks = *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    set $stage = 11
  end
  continue
end
if $stage == 11
  if *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__) >= ($idle_start_ticks + __IDLE_TICKS__) && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 1 && *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__) == 1 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned long long*)(0x__TIMER_STATE__+__TIMER_DISPATCH_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE0_TASK_ID_OFFSET__) == $task1_id
    printf "HIT_AFTER_TASK_TERMINATE_MIXED_STATE_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "AFTER_IDLE_WAKE_COUNT=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "AFTER_IDLE_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__)
    printf "AFTER_IDLE_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    printf "AFTER_IDLE_TIMER_DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__TIMER_STATE__+__TIMER_DISPATCH_COUNT_OFFSET__)
    printf "AFTER_IDLE_NEXT_TIMER_ID=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__)
    printf "AFTER_IDLE_QUANTUM=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__)
    printf "AFTER_IDLE_WAKE0_TASK_ID=%u\n", *(unsigned int*)(0x__WAKE_QUEUE__+__WAKE0_TASK_ID_OFFSET__)
    detach
    quit
  end
  continue
end
continue
end
continue
'@

$gdbScriptContent = $gdbTemplate.
    Replace('__ARTIFACT__', $artifactForGdb).
    Replace('__GDBPORT__', $GdbPort).
    Replace('__START__', $startAddress).
    Replace('__SPINPAUSE__', $spinPauseAddress).
    Replace('__STATUS__', $statusAddress).
    Replace('__COMMAND_MAILBOX__', $commandMailboxAddress).
    Replace('__SCHED_STATE__', $schedulerStateAddress).
    Replace('__TASKS__', $schedulerTasksAddress).
    Replace('__WAIT_KIND__', $schedulerWaitKindAddress).
    Replace('__WAIT_TIMEOUT__', $schedulerWaitTimeoutAddress).
    Replace('__TIMER_STATE__', $timerStateAddress).
    Replace('__TIMER_ENTRIES__', $timerEntriesAddress).
    Replace('__WAKE_QUEUE__', $wakeQueueAddress).
    Replace('__WAKE_QUEUE_COUNT__', $wakeQueueCountAddress).
    Replace('__STATUS_TICKS_OFFSET__', $statusTicksOffset).
    Replace('__STATUS_ACK_OFFSET__', $statusCommandSeqAckOffset).
    Replace('__STATUS_LAST_OPCODE_OFFSET__', $statusLastCommandOpcodeOffset).
    Replace('__STATUS_LAST_RESULT_OFFSET__', $statusLastCommandResultOffset).
    Replace('__COMMAND_OPCODE_OFFSET__', $commandOpcodeOffset).
    Replace('__COMMAND_SEQ_OFFSET__', $commandSeqOffset).
    Replace('__COMMAND_ARG0_OFFSET__', $commandArg0Offset).
    Replace('__COMMAND_ARG1_OFFSET__', $commandArg1Offset).
    Replace('__SCHED_TASK_COUNT_OFFSET__', $schedulerTaskCountOffset).
    Replace('__TASK_STRIDE__', $taskStride).
    Replace('__TASK_ID_OFFSET__', $taskIdOffset).
    Replace('__TASK_STATE_OFFSET__', $taskStateOffset).
    Replace('__TIMER_ENTRY_COUNT_OFFSET__', $timerEntryCountOffset).
    Replace('__TIMER_PENDING_WAKE_COUNT_OFFSET__', $timerPendingWakeCountOffset).
    Replace('__TIMER_NEXT_ID_OFFSET__', $timerNextTimerIdOffset).
    Replace('__TIMER_DISPATCH_COUNT_OFFSET__', $timerDispatchCountOffset).
    Replace('__TIMER_QUANTUM_OFFSET__', $timerQuantumOffset).
    Replace('__TIMER_ENTRY_TIMER_ID_OFFSET__', $timerEntryTimerIdOffset).
    Replace('__TIMER_ENTRY_TASK_ID_OFFSET__', $timerEntryTaskIdOffset).
    Replace('__TIMER_ENTRY_STATE_OFFSET__', $timerEntryStateOffset).
    Replace('__WAKE0_TASK_ID_OFFSET__', $wakeEventTaskIdOffset).
    Replace('__WAKE1_TASK_ID_OFFSET__', ($wakeEventStride + $wakeEventTaskIdOffset)).
    Replace('__SCHEDULER_RESET_OPCODE__', $schedulerResetOpcode).
    Replace('__SCHEDULER_DISABLE_OPCODE__', $schedulerDisableOpcode).
    Replace('__TASK_CREATE_OPCODE__', $taskCreateOpcode).
    Replace('__TASK_TERMINATE_OPCODE__', $taskTerminateOpcode).
    Replace('__TASK_WAIT_OPCODE__', $taskWaitOpcode).
    Replace('__TIMER_SET_QUANTUM_OPCODE__', $timerSetQuantumOpcode).
    Replace('__TASK_WAIT_FOR_OPCODE__', $taskWaitForOpcode).
    Replace('__SCHEDULER_WAKE_TASK_OPCODE__', $schedulerWakeTaskOpcode).
    Replace('__TERMINATED_TASK_BUDGET__', $terminatedTaskBudget).
    Replace('__TERMINATED_TASK_PRIORITY__', $terminatedTaskPriority).
    Replace('__SURVIVOR_TASK_BUDGET__', $survivorTaskBudget).
    Replace('__SURVIVOR_TASK_PRIORITY__', $survivorTaskPriority).
    Replace('__TIMER_QUANTUM__', $timerQuantum).
    Replace('__TIMER_DELAY__', $timerDelay).
    Replace('__IDLE_TICKS__', $idleTicksAfterTerminate).
    Replace('__WAIT_KIND_NONE__', $waitConditionNone).
    Replace('__TASK_STATE_READY__', $taskStateReady).
    Replace('__TASK_STATE_TERMINATED__', $taskStateTerminated)

Set-Content -Path $gdbScript -Value $gdbScriptContent -Encoding ascii

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

$qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
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
        throw "Timed out waiting for GDB task-terminate mixed-state probe"
    }

    $gdbOutput = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
    $gdbError = if (Test-Path $gdbStderr) { Get-Content $gdbStderr -Raw } else { "" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProcess.ExitCode)) { 0 } else { [int]$gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        throw "GDB task-terminate mixed-state probe failed with exit code $gdbExitCode. stdout: $gdbOutput stderr: $gdbError"
    }
}
finally {
    if ($qemuProcess -and -not $qemuProcess.HasExited) {
        Stop-Process -Id $qemuProcess.Id -Force
        $qemuProcess.WaitForExit()
    }
}

$probeText = if (Test-Path $gdbStdout) { Get-Content -Path $gdbStdout -Raw } else { "" }
if ($probeText -notmatch 'HIT_AFTER_TASK_TERMINATE_MIXED_STATE_PROBE') {
    if (-not [string]::IsNullOrWhiteSpace($probeText)) { Write-Output $probeText }
    throw "Task terminate mixed-state probe did not reach completion sentinel"
}

$required = @(
    @{ Name = 'ACK'; Expected = 10 },
    @{ Name = 'LAST_OPCODE'; Expected = $taskTerminateOpcode },
    @{ Name = 'LAST_RESULT'; Expected = 0 },
    @{ Name = 'PRE_WAKE_COUNT'; Expected = 2 },
    @{ Name = 'PRE_PENDING_WAKE_COUNT'; Expected = 2 },
    @{ Name = 'PRE_TIMER_COUNT'; Expected = 0 },
    @{ Name = 'PRE_NEXT_TIMER_ID'; Expected = 2 },
    @{ Name = 'PRE_QUANTUM'; Expected = $timerQuantum },
    @{ Name = 'PRE_TIMER0_STATE'; Expected = 3 },
    @{ Name = 'POST_TASK_COUNT'; Expected = 1 },
    @{ Name = 'POST_WAKE_COUNT'; Expected = 1 },
    @{ Name = 'POST_PENDING_WAKE_COUNT'; Expected = 1 },
    @{ Name = 'POST_TIMER_COUNT'; Expected = 0 },
    @{ Name = 'POST_NEXT_TIMER_ID'; Expected = 2 },
    @{ Name = 'POST_QUANTUM'; Expected = $timerQuantum },
    @{ Name = 'POST_TIMER0_STATE'; Expected = 3 },
    @{ Name = 'POST_TASK0_STATE'; Expected = $taskStateTerminated },
    @{ Name = 'POST_TASK1_STATE'; Expected = $taskStateReady },
    @{ Name = 'POST_WAIT_KIND0'; Expected = $waitConditionNone },
    @{ Name = 'POST_WAIT_KIND1'; Expected = $waitConditionNone },
    @{ Name = 'POST_WAIT_TIMEOUT0'; Expected = 0 },
    @{ Name = 'POST_WAIT_TIMEOUT1'; Expected = 0 },
    @{ Name = 'AFTER_IDLE_WAKE_COUNT'; Expected = 1 },
    @{ Name = 'AFTER_IDLE_PENDING_WAKE_COUNT'; Expected = 1 },
    @{ Name = 'AFTER_IDLE_TIMER_COUNT'; Expected = 0 },
    @{ Name = 'AFTER_IDLE_TIMER_DISPATCH_COUNT'; Expected = 0 },
    @{ Name = 'AFTER_IDLE_NEXT_TIMER_ID'; Expected = 2 },
    @{ Name = 'AFTER_IDLE_QUANTUM'; Expected = $timerQuantum }
)

foreach ($item in $required) {
    $value = Extract-IntValue -Text $probeText -Name $item.Name
    if ($null -eq $value) {
        throw "Missing probe output value for $($item.Name)"
    }
    if ($value -ne $item.Expected) {
        throw "Unexpected $($item.Name): got $value expected $($item.Expected)"
    }
}

$preTerminatedTaskId = Extract-IntValue -Text $probeText -Name 'PRE_TERMINATED_TASK_ID'
$preSurvivorTaskId = Extract-IntValue -Text $probeText -Name 'PRE_SURVIVOR_TASK_ID'
$preWake0TaskId = Extract-IntValue -Text $probeText -Name 'PRE_WAKE0_TASK_ID'
$preWake1TaskId = Extract-IntValue -Text $probeText -Name 'PRE_WAKE1_TASK_ID'
$postWake0TaskId = Extract-IntValue -Text $probeText -Name 'POST_WAKE0_TASK_ID'
$afterIdleWake0TaskId = Extract-IntValue -Text $probeText -Name 'AFTER_IDLE_WAKE0_TASK_ID'

if ($null -eq $preTerminatedTaskId -or $null -eq $preSurvivorTaskId) {
    throw "Missing task id outputs from probe"
}
if ($preTerminatedTaskId -eq 0 -or $preSurvivorTaskId -eq 0 -or $preTerminatedTaskId -eq $preSurvivorTaskId) {
    throw "Probe task ids are invalid: terminated=$preTerminatedTaskId survivor=$preSurvivorTaskId"
}
if ($preWake0TaskId -ne $preTerminatedTaskId) {
    throw "Unexpected PRE_WAKE0_TASK_ID: got $preWake0TaskId expected $preTerminatedTaskId"
}
if ($preWake1TaskId -ne $preSurvivorTaskId) {
    throw "Unexpected PRE_WAKE1_TASK_ID: got $preWake1TaskId expected $preSurvivorTaskId"
}
if ($postWake0TaskId -ne $preSurvivorTaskId) {
    throw "Unexpected POST_WAKE0_TASK_ID: got $postWake0TaskId expected $preSurvivorTaskId"
}
if ($afterIdleWake0TaskId -ne $preSurvivorTaskId) {
    throw "Unexpected AFTER_IDLE_WAKE0_TASK_ID: got $afterIdleWake0TaskId expected $preSurvivorTaskId"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_TASK_TERMINATE_MIXED_STATE_PROBE=pass"
$probeText.TrimEnd()
