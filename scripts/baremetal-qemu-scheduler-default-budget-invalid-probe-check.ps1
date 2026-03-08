param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-command-loop-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-command-loop.elf"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")
$gdbScript = Join-Path $releaseDir "qemu-scheduler-default-budget-invalid-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-scheduler-default-budget-invalid-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-scheduler-default-budget-invalid-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-scheduler-default-budget-invalid-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-scheduler-default-budget-invalid-$runStamp.qemu.stderr.log"

$schedulerDisableOpcode = 25
$schedulerSetDefaultBudgetOpcode = 30
$taskCreateOpcode = 27
$resultOk = 0
$resultInvalid = -22
$defaultBudget = 9

$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$schedulerTaskCountOffset = 1
$schedulerDefaultBudgetOffset = 28
$taskStride = 40
$taskIdOffset = 0
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

function Invoke-CommandLoopArtifactBuildIfNeeded {
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Scheduler default-budget prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
    if ($SkipBuild) { return }
    if (-not (Test-Path $prerequisiteScript)) { throw "Prerequisite script not found: $prerequisiteScript" }
    $prereqOutput = & $prerequisiteScript 2>&1
    $prereqExitCode = $LASTEXITCODE
    if ($prereqExitCode -ne 0) {
        if ($null -ne $prereqOutput) { $prereqOutput | Write-Output }
        throw "Command-loop prerequisite failed with exit code $prereqExitCode"
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable
if ($GdbPort -le 0) { $GdbPort = Resolve-FreeTcpPort }

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_PROBE=skipped"
    exit 0
}

if (-not (Test-Path $artifact)) {
    Invoke-CommandLoopArtifactBuildIfNeeded
} elseif (-not $SkipBuild) {
    Invoke-CommandLoopArtifactBuildIfNeeded
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
$artifactForGdb = $artifact.Replace('\', '/')

@"
set pagination off
set confirm off
set `$stage = 0
set `$task0_id = 0
set `$task0_budget = 0
set `$task0_remaining = 0
set `$task1_id = 0
set `$task1_budget = 0
set `$task1_remaining = 0
set `$post_invalid_task_count = 0
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START\n"
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerDisableOpcode
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerSetDefaultBudgetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $defaultBudget
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned int*)(0x$schedulerStateAddress+$schedulerDefaultBudgetOffset) == $defaultBudget
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 1
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 1 && *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset) != 0
    set `$task0_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskIdOffset)
    set `$task0_budget = *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetOffset)
    set `$task0_remaining = *(unsigned int*)(0x$schedulerTasksAddress+$taskBudgetRemainingOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $schedulerSetDefaultBudgetOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultInvalid && *(unsigned int*)(0x$schedulerStateAddress+$schedulerDefaultBudgetOffset) == $defaultBudget
    set `$post_invalid_task_count = *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $taskCreateOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 2
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset) == 2 && *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset) != 0
    set `$task1_id = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskIdOffset)
    set `$task1_budget = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetOffset)
    set `$task1_remaining = *(unsigned int*)(0x$schedulerTasksAddress+$taskStride+$taskBudgetRemainingOffset)
    printf "AFTER_SCHEDULER_DEFAULT_BUDGET_INVALID\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "DEFAULT_BUDGET=%u\n", *(unsigned int*)(0x$schedulerStateAddress+$schedulerDefaultBudgetOffset)
    printf "TASK_COUNT=%u\n", *(unsigned char*)(0x$schedulerStateAddress+$schedulerTaskCountOffset)
    printf "POST_INVALID_TASK_COUNT=%u\n", `$post_invalid_task_count
    printf "TASK0_ID=%u\n", `$task0_id
    printf "TASK0_BUDGET=%u\n", `$task0_budget
    printf "TASK0_REMAINING=%u\n", `$task0_remaining
    printf "TASK1_ID=%u\n", `$task1_id
    printf "TASK1_BUDGET=%u\n", `$task1_budget
    printf "TASK1_REMAINING=%u\n", `$task1_remaining
    quit
  end
  continue
end
continue
end
continue
"@ | Set-Content -Path $gdbScript -Encoding Ascii

$qemuArgs = @("-kernel", $artifact, "-nographic", "-no-reboot", "-no-shutdown", "-serial", "none", "-monitor", "none", "-S", "-gdb", "tcp::$GdbPort")
$qemuProc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr
Start-Sleep -Milliseconds 700
$gdbProc = Start-Process -FilePath $gdb -ArgumentList @("-q", "-batch", "-x", $gdbScript) -PassThru -NoNewWindow -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr

$timedOut = $false
try {
    $null = Wait-Process -Id $gdbProc.Id -Timeout $TimeoutSeconds -ErrorAction Stop
} catch {
    $timedOut = $true
    try { Stop-Process -Id $gdbProc.Id -Force -ErrorAction SilentlyContinue } catch {}
} finally {
    try { Stop-Process -Id $qemuProc.Id -Force -ErrorAction SilentlyContinue } catch {}
}

$out = if (Test-Path $gdbStdout) { Get-Content -Raw $gdbStdout } else { "" }
$err = if (Test-Path $gdbStderr) { Get-Content -Raw $gdbStderr } else { "" }
$hitStart = $out -match 'HIT_START'
$hitAfter = $out -match 'AFTER_SCHEDULER_DEFAULT_BUDGET_INVALID'
$ack = Extract-IntValue -Text $out -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $out -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $out -Name 'LAST_RESULT'
$defaultBudgetActual = Extract-IntValue -Text $out -Name 'DEFAULT_BUDGET'
$taskCount = Extract-IntValue -Text $out -Name 'TASK_COUNT'
$postInvalidTaskCount = Extract-IntValue -Text $out -Name 'POST_INVALID_TASK_COUNT'
$task0Id = Extract-IntValue -Text $out -Name 'TASK0_ID'
$task0Budget = Extract-IntValue -Text $out -Name 'TASK0_BUDGET'
$task0Remaining = Extract-IntValue -Text $out -Name 'TASK0_REMAINING'
$task1Id = Extract-IntValue -Text $out -Name 'TASK1_ID'
$task1Budget = Extract-IntValue -Text $out -Name 'TASK1_BUDGET'
$task1Remaining = Extract-IntValue -Text $out -Name 'TASK1_REMAINING'

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_QEMU_STDERR=$qemuStderr"

$pass = (
    $hitStart -and
    $hitAfter -and
    (-not $timedOut) -and
    $ack -eq 5 -and
    $lastOpcode -eq $taskCreateOpcode -and
    $lastResult -eq $resultOk -and
    $defaultBudgetActual -eq $defaultBudget -and
    $taskCount -eq 2 -and
    $postInvalidTaskCount -eq 1 -and
    $task0Id -gt 0 -and
    $task0Budget -eq $defaultBudget -and
    $task0Remaining -eq $defaultBudget -and
    $task1Id -gt $task0Id -and
    $task1Budget -eq $defaultBudget -and
    $task1Remaining -eq $defaultBudget
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_PROBE=pass"
    exit 0
}

Write-Output $out
if ($err) { Write-Output $err }
Write-Output "BAREMETAL_QEMU_SCHEDULER_DEFAULT_BUDGET_INVALID_PROBE=fail"
exit 1
