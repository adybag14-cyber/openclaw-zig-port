param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1288
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-scheduler-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-scheduler-policy-switch-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-scheduler-policy-switch-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-scheduler-policy-switch-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-scheduler-policy-switch-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-scheduler-policy-switch-probe.qemu.stderr.log"

$schedulerResetOpcode = 26
$wakeQueueClearOpcode = 44
$schedulerDisableOpcode = 25
$taskCreateOpcode = 27
$schedulerEnableOpcode = 24
$schedulerSetPolicyOpcode = 55
$taskSetPriorityOpcode = 56

$taskBudget = 6
$lowTaskPriority = 1
$highTaskPriority = 9
$boostedLowPriority = 15
$schedulerRoundRobinPolicy = 0
$schedulerPriorityPolicy = 1

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
$schedulerRunningSlotOffset = 2
$schedulerDispatchCountOffset = 8

$taskStride = 40
$taskIdOffset = 0
$taskStateOffset = 4
$taskPriorityOffset = 5
$taskRunCountOffset = 8
$taskBudgetOffset = 12
$taskBudgetRemainingOffset = 16

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
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Scheduler policy switch prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PROBE=skipped"
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
$schedulerPolicyAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.scheduler_policy$' -SymbolName "baremetal_main.scheduler_policy"

$artifactForGdb = $artifact.Replace('\', '/')
foreach ($path in @($gdbStdout, $gdbStderr, $qemuStdout, $qemuStderr)) {
    if (Test-Path $path) { Remove-Item -Force $path }
}

$gdbTemplate = @'
set pagination off
set confirm off
set $stage = 0
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
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_DISABLE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 3
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 3
  end
  continue
end
if $stage == 3
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 3
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 4
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __LOW_PRIORITY__
    set $stage = 4
  end
  continue
end
if $stage == 4
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 4 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK0_ID_OFFSET__) == 1
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_CREATE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 5
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __TASK_BUDGET__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __HIGH_PRIORITY__
    set $stage = 5
  end
  continue
end
if $stage == 5
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 5 && *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TASKS__+__TASK1_ID_OFFSET__) == 2
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_ENABLE_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 6
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 0
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 6
  end
  continue
end
if $stage == 6
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 6 && *(unsigned char*)0x__SCHED_POLICY__ == __ROUND_ROBIN_POLICY__ && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_REMAINING_OFFSET__) == 5 && *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_REMAINING_OFFSET__) == 5
    printf "RR_BASELINE_POLICY=%u\n", *(unsigned char*)0x__SCHED_POLICY__
    printf "RR_BASELINE_LOW_ID=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_ID_OFFSET__)
    printf "RR_BASELINE_HIGH_ID=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_ID_OFFSET__)
    printf "RR_BASELINE_LOW_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__)
    printf "RR_BASELINE_HIGH_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_SET_POLICY_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 7
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __PRIORITY_POLICY__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 7
  end
  continue
end
if $stage == 7
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 7 && *(unsigned char*)0x__SCHED_POLICY__ == __PRIORITY_POLICY__ && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 3 && *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__) == 1 && *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_REMAINING_OFFSET__) == 4
    printf "PRIORITY_POLICY=%u\n", *(unsigned char*)0x__SCHED_POLICY__
    printf "PRIORITY_LOW_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__)
    printf "PRIORITY_HIGH_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__)
    printf "PRIORITY_HIGH_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_REMAINING_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __TASK_SET_PRIORITY_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 8
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = *(unsigned int*)(0x__TASKS__+__TASK0_ID_OFFSET__)
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = __BOOSTED_LOW_PRIORITY__
    set $stage = 8
  end
  continue
end
if $stage == 8
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 8 && *(unsigned char*)0x__SCHED_POLICY__ == __PRIORITY_POLICY__ && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 4 && *(unsigned char*)(0x__TASKS__+__TASK0_PRIORITY_OFFSET__) == __BOOSTED_LOW_PRIORITY__ && *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_REMAINING_OFFSET__) == 4
    printf "REPRIORITIZED_LOW_PRIORITY=%u\n", *(unsigned char*)(0x__TASKS__+__TASK0_PRIORITY_OFFSET__)
    printf "REPRIORITIZED_LOW_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__)
    printf "REPRIORITIZED_HIGH_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__)
    printf "REPRIORITIZED_LOW_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_REMAINING_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_SET_POLICY_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 9
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = __ROUND_ROBIN_POLICY__
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 9
  end
  continue
end
if $stage == 9
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 9 && *(unsigned char*)0x__SCHED_POLICY__ == __ROUND_ROBIN_POLICY__ && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 5 && *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__) == 2 && *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__) == 3 && *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_REMAINING_OFFSET__) == 3
    printf "RR_RETURN_POLICY=%u\n", *(unsigned char*)0x__SCHED_POLICY__
    printf "RR_RETURN_LOW_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__)
    printf "RR_RETURN_HIGH_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__)
    printf "RR_RETURN_HIGH_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_REMAINING_OFFSET__)
    set *(unsigned short*)(0x__COMMAND_MAILBOX__+__COMMAND_OPCODE_OFFSET__) = __SCHEDULER_SET_POLICY_OPCODE__
    set *(unsigned int*)(0x__COMMAND_MAILBOX__+__COMMAND_SEQ_OFFSET__) = 10
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG0_OFFSET__) = 9
    set *(unsigned long long*)(0x__COMMAND_MAILBOX__+__COMMAND_ARG1_OFFSET__) = 0
    set $stage = 10
  end
  continue
end
if $stage == 10
  if *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__) == 10 && *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__) == __SCHEDULER_SET_POLICY_OPCODE__ && *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__) == -22 && *(unsigned char*)0x__SCHED_POLICY__ == __ROUND_ROBIN_POLICY__ && *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__) == 6 && *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__) == 3 && *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__) == 3 && *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_REMAINING_OFFSET__) == 3 && *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_REMAINING_OFFSET__) == 3
    printf "HIT_AFTER_SCHEDULER_POLICY_SWITCH_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x__STATUS__+__STATUS_ACK_OFFSET__)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x__STATUS__+__STATUS_LAST_OPCODE_OFFSET__)
    printf "LAST_RESULT=%d\n", *(short*)(0x__STATUS__+__STATUS_LAST_RESULT_OFFSET__)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x__STATUS__+__STATUS_TICKS_OFFSET__)
    printf "POLICY=%u\n", *(unsigned char*)0x__SCHED_POLICY__
    printf "TASK_COUNT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_TASK_COUNT_OFFSET__)
    printf "RUNNING_SLOT=%u\n", *(unsigned char*)(0x__SCHED_STATE__+__SCHED_RUNNING_SLOT_OFFSET__)
    printf "DISPATCH_COUNT=%llu\n", *(unsigned long long*)(0x__SCHED_STATE__+__SCHED_DISPATCH_COUNT_OFFSET__)
    printf "LOW_ID=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_ID_OFFSET__)
    printf "HIGH_ID=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_ID_OFFSET__)
    printf "LOW_PRIORITY=%u\n", *(unsigned char*)(0x__TASKS__+__TASK0_PRIORITY_OFFSET__)
    printf "HIGH_PRIORITY=%u\n", *(unsigned char*)(0x__TASKS__+__TASK1_PRIORITY_OFFSET__)
    printf "LOW_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_RUN_COUNT_OFFSET__)
    printf "HIGH_RUN=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_RUN_COUNT_OFFSET__)
    printf "LOW_BUDGET=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_OFFSET__)
    printf "HIGH_BUDGET=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_OFFSET__)
    printf "LOW_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x__TASKS__+__TASK0_BUDGET_REMAINING_OFFSET__)
    printf "HIGH_BUDGET_REMAINING=%u\n", *(unsigned int*)(0x__TASKS__+__TASK1_BUDGET_REMAINING_OFFSET__)
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
    Replace('__STATUS_TICKS_OFFSET__', [string]$statusTicksOffset).
    Replace('__STATUS_ACK_OFFSET__', [string]$statusCommandSeqAckOffset).
    Replace('__STATUS_LAST_OPCODE_OFFSET__', [string]$statusLastCommandOpcodeOffset).
    Replace('__STATUS_LAST_RESULT_OFFSET__', [string]$statusLastCommandResultOffset).
    Replace('__COMMAND_MAILBOX__', $commandMailboxAddress).
    Replace('__COMMAND_OPCODE_OFFSET__', [string]$commandOpcodeOffset).
    Replace('__COMMAND_SEQ_OFFSET__', [string]$commandSeqOffset).
    Replace('__COMMAND_ARG0_OFFSET__', [string]$commandArg0Offset).
    Replace('__COMMAND_ARG1_OFFSET__', [string]$commandArg1Offset).
    Replace('__SCHED_STATE__', $schedulerStateAddress).
    Replace('__TASKS__', $schedulerTasksAddress).
    Replace('__SCHED_POLICY__', $schedulerPolicyAddress).
    Replace('__SCHEDULER_RESET_OPCODE__', [string]$schedulerResetOpcode).
    Replace('__WAKE_QUEUE_CLEAR_OPCODE__', [string]$wakeQueueClearOpcode).
    Replace('__SCHEDULER_DISABLE_OPCODE__', [string]$schedulerDisableOpcode).
    Replace('__TASK_CREATE_OPCODE__', [string]$taskCreateOpcode).
    Replace('__SCHEDULER_ENABLE_OPCODE__', [string]$schedulerEnableOpcode).
    Replace('__SCHEDULER_SET_POLICY_OPCODE__', [string]$schedulerSetPolicyOpcode).
    Replace('__TASK_SET_PRIORITY_OPCODE__', [string]$taskSetPriorityOpcode).
    Replace('__TASK_BUDGET__', [string]$taskBudget).
    Replace('__LOW_PRIORITY__', [string]$lowTaskPriority).
    Replace('__HIGH_PRIORITY__', [string]$highTaskPriority).
    Replace('__BOOSTED_LOW_PRIORITY__', [string]$boostedLowPriority).
    Replace('__ROUND_ROBIN_POLICY__', [string]$schedulerRoundRobinPolicy).
    Replace('__PRIORITY_POLICY__', [string]$schedulerPriorityPolicy).
    Replace('__SCHED_ENABLED_OFFSET__', [string]$schedulerEnabledOffset).
    Replace('__SCHED_TASK_COUNT_OFFSET__', [string]$schedulerTaskCountOffset).
    Replace('__SCHED_RUNNING_SLOT_OFFSET__', [string]$schedulerRunningSlotOffset).
    Replace('__SCHED_DISPATCH_COUNT_OFFSET__', [string]$schedulerDispatchCountOffset).
    Replace('__TASK0_ID_OFFSET__', [string]$taskIdOffset).
    Replace('__TASK0_STATE_OFFSET__', [string]$taskStateOffset).
    Replace('__TASK0_PRIORITY_OFFSET__', [string]$taskPriorityOffset).
    Replace('__TASK0_RUN_COUNT_OFFSET__', [string]$taskRunCountOffset).
    Replace('__TASK0_BUDGET_OFFSET__', [string]$taskBudgetOffset).
    Replace('__TASK0_BUDGET_REMAINING_OFFSET__', [string]$taskBudgetRemainingOffset).
    Replace('__TASK1_ID_OFFSET__', [string]($taskStride + $taskIdOffset)).
    Replace('__TASK1_STATE_OFFSET__', [string]($taskStride + $taskStateOffset)).
    Replace('__TASK1_PRIORITY_OFFSET__', [string]($taskStride + $taskPriorityOffset)).
    Replace('__TASK1_RUN_COUNT_OFFSET__', [string]($taskStride + $taskRunCountOffset)).
    Replace('__TASK1_BUDGET_OFFSET__', [string]($taskStride + $taskBudgetOffset)).
    Replace('__TASK1_BUDGET_REMAINING_OFFSET__', [string]($taskStride + $taskBudgetRemainingOffset))

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
        throw "Timed out waiting for GDB scheduler policy switch probe"
    }

    $gdbOutput = if (Test-Path $gdbStdout) { Get-Content $gdbStdout -Raw } else { "" }
    $gdbError = if (Test-Path $gdbStderr) { Get-Content $gdbStderr -Raw } else { "" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode -or [string]::IsNullOrWhiteSpace([string]$gdbProcess.ExitCode)) { 0 } else { [int]$gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        throw "GDB scheduler policy switch probe failed with exit code $gdbExitCode. stdout: $gdbOutput stderr: $gdbError"
    }

    foreach ($requiredMarker in @("HIT_START", "HIT_AFTER_SCHEDULER_POLICY_SWITCH_PROBE")) {
        if ($gdbOutput -notmatch [regex]::Escape($requiredMarker)) {
            throw "Missing expected marker '$requiredMarker' in GDB output. stdout: $gdbOutput stderr: $gdbError"
        }
    }

    $expectations = @{
        "RR_BASELINE_POLICY" = $schedulerRoundRobinPolicy
        "RR_BASELINE_LOW_ID" = 1
        "RR_BASELINE_HIGH_ID" = 2
        "RR_BASELINE_LOW_RUN" = 1
        "RR_BASELINE_HIGH_RUN" = 1
        "PRIORITY_POLICY" = $schedulerPriorityPolicy
        "PRIORITY_LOW_RUN" = 1
        "PRIORITY_HIGH_RUN" = 2
        "PRIORITY_HIGH_BUDGET_REMAINING" = 4
        "REPRIORITIZED_LOW_PRIORITY" = $boostedLowPriority
        "REPRIORITIZED_LOW_RUN" = 2
        "REPRIORITIZED_HIGH_RUN" = 2
        "REPRIORITIZED_LOW_BUDGET_REMAINING" = 4
        "RR_RETURN_POLICY" = $schedulerRoundRobinPolicy
        "RR_RETURN_LOW_RUN" = 2
        "RR_RETURN_HIGH_RUN" = 3
        "RR_RETURN_HIGH_BUDGET_REMAINING" = 3
        "ACK" = 10
        "LAST_OPCODE" = $schedulerSetPolicyOpcode
        "LAST_RESULT" = -22
        "POLICY" = $schedulerRoundRobinPolicy
        "TASK_COUNT" = 2
        "RUNNING_SLOT" = 0
        "DISPATCH_COUNT" = 6
        "LOW_ID" = 1
        "HIGH_ID" = 2
        "LOW_PRIORITY" = $boostedLowPriority
        "HIGH_PRIORITY" = $highTaskPriority
        "LOW_RUN" = 3
        "HIGH_RUN" = 3
        "LOW_BUDGET" = $taskBudget
        "HIGH_BUDGET" = $taskBudget
        "LOW_BUDGET_REMAINING" = 3
        "HIGH_BUDGET_REMAINING" = 3
    }

    foreach ($name in $expectations.Keys) {
        $actual = Extract-IntValue -Text $gdbOutput -Name $name
        if ($null -eq $actual) {
            throw "Missing expected field '$name' in probe output. stdout: $gdbOutput stderr: $gdbError"
        }
        if ($actual -ne [int64]$expectations[$name]) {
            throw "Unexpected value for $name. Expected $($expectations[$name]), got $actual. stdout: $gdbOutput stderr: $gdbError"
        }
    }

    $ticks = Extract-IntValue -Text $gdbOutput -Name "TICKS"
    if ($null -eq $ticks -or $ticks -lt 10) {
        throw "Unexpected TICKS value. Expected at least 10, got $ticks. stdout: $gdbOutput stderr: $gdbError"
    }

    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_POLICY_SWITCH_PROBE=pass"
    $gdbOutput.TrimEnd()
} finally {
    if ($null -ne $qemuProcess -and -not $qemuProcess.HasExited) {
        try { $qemuProcess.Kill() } catch {}
        try { $qemuProcess.WaitForExit() } catch {}
    }
}
