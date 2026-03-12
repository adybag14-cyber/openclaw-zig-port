param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 1314
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-reset-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-scheduler-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-scheduler-reset-mixed-state-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-scheduler-reset-mixed-state-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-scheduler-reset-mixed-state-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-scheduler-reset-mixed-state-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-scheduler-reset-mixed-state-probe.qemu.stderr.log"

$schedulerResetOpcode = 26
$taskCreateOpcode = 27
$timerSetQuantumOpcode = 48
$taskWaitForOpcode = 53
$taskWaitInterruptForOpcode = 58
$schedulerWakeTaskOpcode = 45

$timerTaskBudget = 5
$timerTaskPriority = 0
$interruptTaskBudget = 6
$interruptTaskPriority = 1
$freshTaskBudget = 4
$freshTaskPriority = 9
$timerQuantum = 5
$timerDelay = 10
$interruptTimeout = 20
$rearmDelay = 3
$idleTicksAfterReset = 25

$waitConditionNone = 0
$waitConditionInterruptAny = 3

$taskStateReady = 1
$taskStateWaiting = 6

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$schedulerEnabledOffset = 0
$schedulerTaskCountOffset = 1
$schedulerNextTaskIdOffset = 4

$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4

$timerEnabledOffset = 0
$timerEntryCountOffset = 1
$timerPendingWakeCountOffset = 2
$timerNextTimerIdOffset = 4
$timerQuantumOffset = 40

$timerEntryStride = 40
$timerEntryTimerIdOffset = 0

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
        throw "Scheduler reset mixed-state prerequisite artifact not found at $artifact and -SkipBuild was supplied."
    }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) { throw "Prerequisite script not found: $prerequisiteScript" }
    $prereqOutput = & $prerequisiteScript 2>&1
    $prereqExitCode = $LASTEXITCODE
    if ($prereqExitCode -ne 0) {
        if ($null -ne $prereqOutput) { $prereqOutput | Write-Output }
        throw "Scheduler reset mixed-state prerequisite failed with exit code $prereqExitCode"
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped"
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
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 2
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __TIMER_TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __TIMER_TASK_PRIORITY__
    set $stage = 2
  end
  continue
end
if $stage == 2
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 2
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 3
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __INTERRUPT_TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __INTERRUPT_TASK_PRIORITY__
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 3
    set $task0_id = *(unsigned int*)(0x__TASKS__+__TASK_ID_OFFSET__)
    set $task1_id = *(unsigned int*)(0x__TASKS__+__TASK_STRIDE__+__TASK_ID_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TIMER_SET_QUANTUM_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 4
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __TIMER_QUANTUM__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 4
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_WAIT_FOR_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 5
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task0_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __TIMER_DELAY__
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 5
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_WAIT_INTERRUPT_FOR_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 6
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task1_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __INTERRUPT_TIMEOUT__
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 6
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_WAKE_TASK_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 7
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $task0_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 7 && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 1 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__) == 2 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__) == __TIMER_QUANTUM__ && *(unsigned char*)(0x__TASKS__+__TASK_STATE_OFFSET__) == __TASK_STATE_READY__ && *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK_STATE_OFFSET__) == __TASK_STATE_WAITING__ && *(unsigned char*)(0x__WAIT_KIND__) == __WAIT_KIND_NONE__ && *(unsigned char*)(0x__WAIT_KIND__+1) == __WAIT_KIND_INTERRUPT_ANY__ && *(unsigned long long*)(0x__WAIT_TIMEOUT__+8) > 0
    printf "PRE_TASK0_ID=%u\n", $task0_id
    printf "PRE_TASK1_ID=%u\n", $task1_id
    printf "PRE_WAKE_COUNT=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "PRE_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    printf "PRE_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__)
    printf "PRE_NEXT_TIMER_ID=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__)
    printf "PRE_QUANTUM=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__)
    printf "PRE_TASK0_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK_STATE_OFFSET__)
    printf "PRE_TASK1_STATE=%u\n", *(unsigned char*)(0x__TASKS__+__TASK_STRIDE__+__TASK_STATE_OFFSET__)
    printf "PRE_WAIT_KIND0=%u\n", *(unsigned char*)(0x__WAIT_KIND__)
    printf "PRE_WAIT_KIND1=%u\n", *(unsigned char*)(0x__WAIT_KIND__+1)
    printf "PRE_WAIT_TIMEOUT1=%llu\n", *(unsigned long long*)(0x__WAIT_TIMEOUT__+8)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_RESET_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 8
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 8
  end
  continue
end
if $stage == 8
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 8 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_ENABLED_OFFSET__) == 0 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__SCHED_STATE__+__SCHED_NEXT_TASK_ID_OFFSET__) == 1 && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 0 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 0 && *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__) == 0 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__) == 2 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__) == __TIMER_QUANTUM__ && *(unsigned char*)(0x__WAIT_KIND__) == __WAIT_KIND_NONE__ && *(unsigned char*)(0x__WAIT_KIND__+1) == __WAIT_KIND_NONE__ && *(unsigned long long*)(0x__WAIT_TIMEOUT__) == 0 && *(unsigned long long*)(0x__WAIT_TIMEOUT__+8) == 0
    printf "POST_TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "POST_WAKE_COUNT=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "POST_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    printf "POST_PENDING_WAKE_COUNT=%u\n", *(unsigned short*)(0x__TIMER_STATE__+__TIMER_PENDING_WAKE_COUNT_OFFSET__)
    printf "POST_NEXT_TIMER_ID=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__)
    printf "POST_QUANTUM=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_QUANTUM_OFFSET__)
    printf "POST_WAIT_KIND0=%u\n", *(unsigned char*)(0x__WAIT_KIND__)
    printf "POST_WAIT_KIND1=%u\n", *(unsigned char*)(0x__WAIT_KIND__+1)
    printf "POST_WAIT_TIMEOUT0=%llu\n", *(unsigned long long*)(0x__WAIT_TIMEOUT__)
    printf "POST_WAIT_TIMEOUT1=%llu\n", *(unsigned long long*)(0x__WAIT_TIMEOUT__+8)
    set $idle_start_ticks = *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    set $stage = 9
  end
  continue
end
if $stage == 9
  if *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__) >= ($idle_start_ticks + __IDLE_TICKS__) && *(unsigned int*)(0x__WAKE_QUEUE_COUNT__) == 0 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 0
    printf "AFTER_IDLE_WAKE_COUNT=%u\n", *(unsigned int*)(0x__WAKE_QUEUE_COUNT__)
    printf "AFTER_IDLE_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 9
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __FRESH_TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __FRESH_TASK_PRIORITY__
    set $stage = 10
  end
  continue
end
if $stage == 10
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 9 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK_ID_OFFSET__) == 1 && *(unsigned char*)(0x__TASKS__+__TASK_STATE_OFFSET__) == __TASK_STATE_READY__
    set $fresh_task_id = *(unsigned int*)(0x__TASKS__+__TASK_ID_OFFSET__)
    printf "FRESH_TASK_ID=%u\n", $fresh_task_id
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_WAIT_FOR_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 10
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = $fresh_task_id
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __REARM_DELAY__
    set $stage = 11
  end
  continue
end
if $stage == 11
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 10 && *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TIMER_ENTRIES__+__TIMER_ENTRY_TIMER_ID_OFFSET__) == 2 && *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__) == 3
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "REARM_TIMER_COUNT=%u\n", *(unsigned char*)(0x__TIMER_STATE__+__TIMER_ENTRY_COUNT_OFFSET__)
    printf "REARM_TIMER_ID=%u\n", *(unsigned int*)(0x__TIMER_ENTRIES__+__TIMER_ENTRY_TIMER_ID_OFFSET__)
    printf "REARM_NEXT_TIMER_ID=%u\n", *(unsigned int*)(0x__TIMER_STATE__+__TIMER_NEXT_ID_OFFSET__)
    printf "AFTER_SCHED_RESET_MIXED_STATE\n"
    quit
  end
  continue
end
continue
end
continue
'@

$gdbScriptContent = $gdbTemplate `
    -replace '__ARTIFACT__', $artifactForGdb `
    -replace '__GDBPORT__', [string]$GdbPort `
    -replace '__START__', $startAddress `
    -replace '__SPINPAUSE__', $spinPauseAddress `
    -replace '__STATUS__', $statusAddress `
    -replace '__COMMAND_MAILBOX__', $commandMailboxAddress `
    -replace '__SCHED_STATE__', $schedulerStateAddress `
    -replace '__TASKS__', $schedulerTasksAddress `
    -replace '__WAIT_KIND__', $schedulerWaitKindAddress `
    -replace '__WAIT_TIMEOUT__', $schedulerWaitTimeoutAddress `
    -replace '__TIMER_STATE__', $timerStateAddress `
    -replace '__TIMER_ENTRIES__', $timerEntriesAddress `
    -replace '__WAKE_QUEUE_COUNT__', $wakeQueueCountAddress `
    -replace '__STATUS_TICKS_OFFSET__', [string]$statusTicksOffset `
    -replace '__STATUS_ACK_OFFSET__', [string]$statusCommandSeqAckOffset `
    -replace '__STATUS_LAST_OPCODE_OFFSET__', [string]$statusLastCommandOpcodeOffset `
    -replace '__STATUS_LAST_RESULT_OFFSET__', [string]$statusLastCommandResultOffset `
    -replace '__COMMAND_OPCODE_OFFSET__', [string]$commandOpcodeOffset `
    -replace '__COMMAND_SEQ_OFFSET__', [string]$commandSeqOffset `
    -replace '__COMMAND_ARG0_OFFSET__', [string]$commandArg0Offset `
    -replace '__COMMAND_ARG1_OFFSET__', [string]$commandArg1Offset `
    -replace '__SCHED_ENABLED_OFFSET__', [string]$schedulerEnabledOffset `
    -replace '__SCHED_TASK_COUNT_OFFSET__', [string]$schedulerTaskCountOffset `
    -replace '__SCHED_NEXT_TASK_ID_OFFSET__', [string]$schedulerNextTaskIdOffset `
    -replace '__TASK_STRIDE__', [string]$taskStride `
    -replace '__TASK_ID_OFFSET__', [string]$taskIdOffset `
    -replace '__TASK_STATE_OFFSET__', [string]$taskStateOffset `
    -replace '__TIMER_ENTRY_COUNT_OFFSET__', [string]$timerEntryCountOffset `
    -replace '__TIMER_PENDING_WAKE_COUNT_OFFSET__', [string]$timerPendingWakeCountOffset `
    -replace '__TIMER_NEXT_ID_OFFSET__', [string]$timerNextTimerIdOffset `
    -replace '__TIMER_QUANTUM_OFFSET__', [string]$timerQuantumOffset `
    -replace '__TIMER_ENTRY_TIMER_ID_OFFSET__', [string]$timerEntryTimerIdOffset `
    -replace '__SCHEDULER_RESET_OPCODE__', [string]$schedulerResetOpcode `
    -replace '__TASK_CREATE_OPCODE__', [string]$taskCreateOpcode `
    -replace '__TIMER_SET_QUANTUM_OPCODE__', [string]$timerSetQuantumOpcode `
    -replace '__TASK_WAIT_FOR_OPCODE__', [string]$taskWaitForOpcode `
    -replace '__TASK_WAIT_INTERRUPT_FOR_OPCODE__', [string]$taskWaitInterruptForOpcode `
    -replace '__SCHEDULER_WAKE_TASK_OPCODE__', [string]$schedulerWakeTaskOpcode `
    -replace '__TIMER_TASK_BUDGET__', [string]$timerTaskBudget `
    -replace '__TIMER_TASK_PRIORITY__', [string]$timerTaskPriority `
    -replace '__INTERRUPT_TASK_BUDGET__', [string]$interruptTaskBudget `
    -replace '__INTERRUPT_TASK_PRIORITY__', [string]$interruptTaskPriority `
    -replace '__FRESH_TASK_BUDGET__', [string]$freshTaskBudget `
    -replace '__FRESH_TASK_PRIORITY__', [string]$freshTaskPriority `
    -replace '__TIMER_QUANTUM__', [string]$timerQuantum `
    -replace '__TIMER_DELAY__', [string]$timerDelay `
    -replace '__INTERRUPT_TIMEOUT__', [string]$interruptTimeout `
    -replace '__REARM_DELAY__', [string]$rearmDelay `
    -replace '__IDLE_TICKS__', [string]$idleTicksAfterReset `
    -replace '__WAIT_KIND_NONE__', [string]$waitConditionNone `
    -replace '__WAIT_KIND_INTERRUPT_ANY__', [string]$waitConditionInterruptAny `
    -replace '__TASK_STATE_READY__', [string]$taskStateReady `
    -replace '__TASK_STATE_WAITING__', [string]$taskStateWaiting

$gdbScriptContent | Set-Content -Path $gdbScript -Encoding Ascii

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
    $hitAfter = $gdbOutput.Contains("AFTER_SCHED_RESET_MIXED_STATE")
}
if (Test-Path $gdbStderr) {
    $gdbError = [string](Get-Content -Path $gdbStderr -Raw)
}

if ($timedOut) {
    throw "QEMU scheduler reset mixed-state probe timed out after $TimeoutSeconds seconds.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$gdbExitCode = if ($null -eq $gdbProc -or $null -eq $gdbProc.ExitCode) { 0 } else { [int] $gdbProc.ExitCode }
if ($gdbExitCode -ne 0) {
    throw "QEMU scheduler reset mixed-state probe gdb exited with code $gdbExitCode.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}
if (-not $hitStart -or -not $hitAfter) {
    throw "QEMU scheduler reset mixed-state probe did not reach expected breakpoints.`nSTDOUT:`n$gdbOutput`nSTDERR:`n$gdbError"
}

$ack = Extract-IntValue -Text $gdbOutput -Name "ACK"
$lastOpcode = Extract-IntValue -Text $gdbOutput -Name "LAST_OPCODE"
$lastResult = Extract-IntValue -Text $gdbOutput -Name "LAST_RESULT"
$preTask0Id = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK0_ID"
$preTask1Id = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK1_ID"
$preWakeCount = Extract-IntValue -Text $gdbOutput -Name "PRE_WAKE_COUNT"
$preTimerCount = Extract-IntValue -Text $gdbOutput -Name "PRE_TIMER_COUNT"
$prePendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "PRE_PENDING_WAKE_COUNT"
$preNextTimerId = Extract-IntValue -Text $gdbOutput -Name "PRE_NEXT_TIMER_ID"
$preQuantum = Extract-IntValue -Text $gdbOutput -Name "PRE_QUANTUM"
$preTask0State = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK0_STATE"
$preTask1State = Extract-IntValue -Text $gdbOutput -Name "PRE_TASK1_STATE"
$preWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "PRE_WAIT_KIND0"
$preWaitKind1 = Extract-IntValue -Text $gdbOutput -Name "PRE_WAIT_KIND1"
$preWaitTimeout1 = Extract-IntValue -Text $gdbOutput -Name "PRE_WAIT_TIMEOUT1"
$postTaskCount = Extract-IntValue -Text $gdbOutput -Name "POST_TASK_COUNT"
$postWakeCount = Extract-IntValue -Text $gdbOutput -Name "POST_WAKE_COUNT"
$postTimerCount = Extract-IntValue -Text $gdbOutput -Name "POST_TIMER_COUNT"
$postPendingWakeCount = Extract-IntValue -Text $gdbOutput -Name "POST_PENDING_WAKE_COUNT"
$postNextTimerId = Extract-IntValue -Text $gdbOutput -Name "POST_NEXT_TIMER_ID"
$postQuantum = Extract-IntValue -Text $gdbOutput -Name "POST_QUANTUM"
$postWaitKind0 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_KIND0"
$postWaitKind1 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_KIND1"
$postWaitTimeout0 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_TIMEOUT0"
$postWaitTimeout1 = Extract-IntValue -Text $gdbOutput -Name "POST_WAIT_TIMEOUT1"
$afterIdleWakeCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_IDLE_WAKE_COUNT"
$afterIdleTimerCount = Extract-IntValue -Text $gdbOutput -Name "AFTER_IDLE_TIMER_COUNT"
$freshTaskId = Extract-IntValue -Text $gdbOutput -Name "FRESH_TASK_ID"
$rearmTimerCount = Extract-IntValue -Text $gdbOutput -Name "REARM_TIMER_COUNT"
$rearmTimerId = Extract-IntValue -Text $gdbOutput -Name "REARM_TIMER_ID"
$rearmNextTimerId = Extract-IntValue -Text $gdbOutput -Name "REARM_NEXT_TIMER_ID"

$checks = @(
    ($ack -eq 10),
    ($lastOpcode -eq $taskWaitForOpcode),
    ($lastResult -eq 0),
    ($preTask0Id -eq 1),
    ($preTask1Id -eq 2),
    ($preWakeCount -eq 1),
    ($preTimerCount -eq 0),
    ($prePendingWakeCount -eq 1),
    ($preNextTimerId -eq 2),
    ($preQuantum -eq $timerQuantum),
    ($preTask0State -eq $taskStateReady),
    ($preTask1State -eq $taskStateWaiting),
    ($preWaitKind0 -eq $waitConditionNone),
    ($preWaitKind1 -eq $waitConditionInterruptAny),
    ($preWaitTimeout1 -gt 0),
    ($postTaskCount -eq 0),
    ($postWakeCount -eq 0),
    ($postTimerCount -eq 0),
    ($postPendingWakeCount -eq 0),
    ($postNextTimerId -eq 2),
    ($postQuantum -eq $timerQuantum),
    ($postWaitKind0 -eq $waitConditionNone),
    ($postWaitKind1 -eq $waitConditionNone),
    ($postWaitTimeout0 -eq 0),
    ($postWaitTimeout1 -eq 0),
    ($afterIdleWakeCount -eq 0),
    ($afterIdleTimerCount -eq 0),
    ($freshTaskId -eq 1),
    ($rearmTimerCount -eq 1),
    ($rearmTimerId -eq 2),
    ($rearmNextTimerId -eq 3)
)

if ($checks -contains $false) {
    throw "QEMU scheduler reset mixed-state probe reported unexpected values.`n$gdbOutput"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_GDB_AVAILABLE=True"
Write-Output "BAREMETAL_NM_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=pass"
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "PRE_WAKE_COUNT=$preWakeCount"
Write-Output "PRE_TIMER_COUNT=$preTimerCount"
Write-Output "PRE_PENDING_WAKE_COUNT=$prePendingWakeCount"
Write-Output "PRE_NEXT_TIMER_ID=$preNextTimerId"
Write-Output "PRE_QUANTUM=$preQuantum"
Write-Output "POST_TASK_COUNT=$postTaskCount"
Write-Output "POST_WAKE_COUNT=$postWakeCount"
Write-Output "POST_TIMER_COUNT=$postTimerCount"
Write-Output "POST_PENDING_WAKE_COUNT=$postPendingWakeCount"
Write-Output "POST_NEXT_TIMER_ID=$postNextTimerId"
Write-Output "POST_QUANTUM=$postQuantum"
Write-Output "POST_WAIT_KIND0=$postWaitKind0"
Write-Output "POST_WAIT_KIND1=$postWaitKind1"
Write-Output "POST_WAIT_TIMEOUT0=$postWaitTimeout0"
Write-Output "POST_WAIT_TIMEOUT1=$postWaitTimeout1"
Write-Output "AFTER_IDLE_WAKE_COUNT=$afterIdleWakeCount"
Write-Output "AFTER_IDLE_TIMER_COUNT=$afterIdleTimerCount"
Write-Output "FRESH_TASK_ID=$freshTaskId"
Write-Output "REARM_TIMER_ID=$rearmTimerId"
Write-Output "REARM_TIMER_COUNT=$rearmTimerCount"
Write-Output "REARM_NEXT_TIMER_ID=$rearmNextTimerId"
