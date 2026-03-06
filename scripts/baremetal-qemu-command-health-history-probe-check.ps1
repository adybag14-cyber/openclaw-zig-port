param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1252
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-descriptor-bootdiag-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-command-health-history-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-command-health-history-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-command-health-history-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-command-health-history-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-command-health-history-probe.qemu.stderr.log"

$setHealthCodeOpcode = 1
$healthCodeBase = 100
$setHealthCountTarget = 35
$commandHistoryCapacity = 32
$healthHistoryCapacity = 64
$commandEventStride = 32
$healthEventStride = 24
$expectedFinalAck = 35
$expectedFinalTickFloor = 36
$expectedCommandHistoryOverflow = 3
$expectedHealthHistoryOverflow = 7
$expectedCommandHead = 3
$expectedHealthHead = 7
$expectedCommandFirstSeq = 4
$expectedCommandFirstArg0 = 103
$expectedCommandLastSeq = 35
$expectedCommandLastArg0 = 134
$expectedHealthFirstSeq = 8
$expectedHealthFirstCode = 103
$expectedHealthFirstAck = 3
$expectedHealthPrevLastSeq = 70
$expectedHealthPrevLastCode = 134
$expectedHealthPrevLastAck = 34
$expectedHealthLastSeq = 71
$expectedHealthLastCode = 200
$expectedHealthLastAck = 35

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$commandHistorySeqOffset = 0
$commandHistoryOpcodeOffset = 4
$commandHistoryResultOffset = 6
$commandHistoryTickOffset = 8
$commandHistoryArg0Offset = 16
$commandHistoryArg1Offset = 24

$healthHistorySeqOffset = 0
$healthHistoryCodeOffset = 4
$healthHistoryModeOffset = 6
$healthHistoryTickOffset = 8
$healthHistoryAckOffset = 16

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
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Command/health history prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
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
    Write-Output "BAREMETAL_QEMU_COMMAND_HEALTH_HISTORY_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_COMMAND_HEALTH_HISTORY_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_COMMAND_HEALTH_HISTORY_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_COMMAND_HEALTH_HISTORY_PROBE=skipped"
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
$commandHistoryHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history_head$' -SymbolName "baremetal_main.command_history_head"
$commandHistoryOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.command_history_overflow$' -SymbolName "baremetal_main.command_history_overflow"
$healthHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history$' -SymbolName "baremetal_main.health_history"
$healthHistoryCountAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_count$' -SymbolName "baremetal_main.health_history_count"
$healthHistoryHeadAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_head$' -SymbolName "baremetal_main.health_history_head"
$healthHistoryOverflowAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_overflow$' -SymbolName "baremetal_main.health_history_overflow"
$healthHistorySeqAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal_main\.health_history_seq$' -SymbolName "baremetal_main.health_history_seq"

$artifactForGdb = $artifact.Replace('\', '/')
if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$expected_seq = 0
set `$health_emitted = 0
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
    set *(unsigned long long*)(0x$statusAddress+$statusTicksOffset) = 0
    set *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) = 0
    set *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset) = 0
    set *(short*)(0x$statusAddress+$statusLastCommandResultOffset) = 0
    set *(unsigned int*)0x$commandHistoryCountAddress = 0
    set *(unsigned int*)0x$commandHistoryHeadAddress = 0
    set *(unsigned int*)0x$commandHistoryOverflowAddress = 0
    set *(unsigned int*)0x$healthHistoryCountAddress = 0
    set *(unsigned int*)0x$healthHistoryHeadAddress = 0
    set *(unsigned int*)0x$healthHistoryOverflowAddress = 0
    set *(unsigned int*)0x$healthHistorySeqAddress = 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = 0
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$expected_seq = 0
    set `$stage = 1
  end
  continue
end
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$expected_seq && `$health_emitted < $setHealthCountTarget
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setHealthCodeOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = `$expected_seq + 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $healthCodeBase + `$health_emitted
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$expected_seq = `$expected_seq + 1
    set `$health_emitted = `$health_emitted + 1
    if `$health_emitted == $setHealthCountTarget
      set `$stage = 2
    end
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == `$expected_seq && *(unsigned int*)0x$commandHistoryCountAddress == $commandHistoryCapacity && *(unsigned int*)0x$commandHistoryOverflowAddress == $expectedCommandHistoryOverflow && *(unsigned int*)0x$healthHistoryCountAddress == $healthHistoryCapacity && *(unsigned int*)0x$healthHistoryOverflowAddress == $expectedHealthHistoryOverflow
    set `$cmd_head = *(unsigned int*)0x$commandHistoryHeadAddress
    set `$cmd_oldest = `$cmd_head
    set `$cmd_newest = (`$cmd_head + $commandHistoryCapacity - 1) % $commandHistoryCapacity
    set `$health_head = *(unsigned int*)0x$healthHistoryHeadAddress
    set `$health_oldest = `$health_head
    set `$health_newest = (`$health_head + $healthHistoryCapacity - 1) % $healthHistoryCapacity
    set `$health_prev_last = (`$health_head + $healthHistoryCapacity - 2) % $healthHistoryCapacity
    printf "HIT_AFTER_COMMAND_HEALTH_HISTORY_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "COMMAND_HISTORY_LEN=%u\n", *(unsigned int*)0x$commandHistoryCountAddress
    printf "COMMAND_HISTORY_OVERFLOW=%u\n", *(unsigned int*)0x$commandHistoryOverflowAddress
    printf "COMMAND_HISTORY_HEAD=%u\n", *(unsigned int*)0x$commandHistoryHeadAddress
    printf "COMMAND_HISTORY_FIRST_SEQ=%u\n", *(unsigned int*)(0x$commandHistoryAddress + (`$cmd_oldest * $commandEventStride) + $commandHistorySeqOffset)
    printf "COMMAND_HISTORY_FIRST_ARG0=%llu\n", *(unsigned long long*)(0x$commandHistoryAddress + (`$cmd_oldest * $commandEventStride) + $commandHistoryArg0Offset)
    printf "COMMAND_HISTORY_LAST_SEQ=%u\n", *(unsigned int*)(0x$commandHistoryAddress + (`$cmd_newest * $commandEventStride) + $commandHistorySeqOffset)
    printf "COMMAND_HISTORY_LAST_ARG0=%llu\n", *(unsigned long long*)(0x$commandHistoryAddress + (`$cmd_newest * $commandEventStride) + $commandHistoryArg0Offset)
    printf "HEALTH_HISTORY_LEN=%u\n", *(unsigned int*)0x$healthHistoryCountAddress
    printf "HEALTH_HISTORY_OVERFLOW=%u\n", *(unsigned int*)0x$healthHistoryOverflowAddress
    printf "HEALTH_HISTORY_HEAD=%u\n", *(unsigned int*)0x$healthHistoryHeadAddress
    printf "HEALTH_HISTORY_FIRST_SEQ=%u\n", *(unsigned int*)(0x$healthHistoryAddress + (`$health_oldest * $healthEventStride) + $healthHistorySeqOffset)
    printf "HEALTH_HISTORY_FIRST_CODE=%u\n", *(unsigned short*)(0x$healthHistoryAddress + (`$health_oldest * $healthEventStride) + $healthHistoryCodeOffset)
    printf "HEALTH_HISTORY_FIRST_ACK=%u\n", *(unsigned int*)(0x$healthHistoryAddress + (`$health_oldest * $healthEventStride) + $healthHistoryAckOffset)
    printf "HEALTH_HISTORY_PREV_LAST_SEQ=%u\n", *(unsigned int*)(0x$healthHistoryAddress + (`$health_prev_last * $healthEventStride) + $healthHistorySeqOffset)
    printf "HEALTH_HISTORY_PREV_LAST_CODE=%u\n", *(unsigned short*)(0x$healthHistoryAddress + (`$health_prev_last * $healthEventStride) + $healthHistoryCodeOffset)
    printf "HEALTH_HISTORY_PREV_LAST_ACK=%u\n", *(unsigned int*)(0x$healthHistoryAddress + (`$health_prev_last * $healthEventStride) + $healthHistoryAckOffset)
    printf "HEALTH_HISTORY_LAST_SEQ=%u\n", *(unsigned int*)(0x$healthHistoryAddress + (`$health_newest * $healthEventStride) + $healthHistorySeqOffset)
    printf "HEALTH_HISTORY_LAST_CODE=%u\n", *(unsigned short*)(0x$healthHistoryAddress + (`$health_newest * $healthEventStride) + $healthHistoryCodeOffset)
    printf "HEALTH_HISTORY_LAST_ACK=%u\n", *(unsigned int*)(0x$healthHistoryAddress + (`$health_newest * $healthEventStride) + $healthHistoryAckOffset)
    detach
    quit
  end
  continue
end
continue
end
continue
"@ | Set-Content -Path $gdbScript -NoNewline

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
    $gdbText | Set-Content -Path $gdbStdout
    $gdbText | Write-Output

    if ($gdbText -notmatch 'HIT_START' -or $gdbText -notmatch 'HIT_AFTER_COMMAND_HEALTH_HISTORY_PROBE') {
        throw "Probe did not reach all expected stages."
    }

    $ack = Extract-IntValue -Text $gdbText -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $gdbText -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $gdbText -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $gdbText -Name "TICKS"
    $commandHistoryLen = Extract-IntValue -Text $gdbText -Name "COMMAND_HISTORY_LEN"
    $commandHistoryOverflow = Extract-IntValue -Text $gdbText -Name "COMMAND_HISTORY_OVERFLOW"
    $commandHistoryHead = Extract-IntValue -Text $gdbText -Name "COMMAND_HISTORY_HEAD"
    $commandHistoryFirstSeq = Extract-IntValue -Text $gdbText -Name "COMMAND_HISTORY_FIRST_SEQ"
    $commandHistoryFirstArg0 = Extract-IntValue -Text $gdbText -Name "COMMAND_HISTORY_FIRST_ARG0"
    $commandHistoryLastSeq = Extract-IntValue -Text $gdbText -Name "COMMAND_HISTORY_LAST_SEQ"
    $commandHistoryLastArg0 = Extract-IntValue -Text $gdbText -Name "COMMAND_HISTORY_LAST_ARG0"
    $healthHistoryLen = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_LEN"
    $healthHistoryOverflow = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_OVERFLOW"
    $healthHistoryHead = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_HEAD"
    $healthHistoryFirstSeq = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_FIRST_SEQ"
    $healthHistoryFirstCode = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_FIRST_CODE"
    $healthHistoryFirstAck = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_FIRST_ACK"
    $healthHistoryPrevLastSeq = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_PREV_LAST_SEQ"
    $healthHistoryPrevLastCode = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_PREV_LAST_CODE"
    $healthHistoryPrevLastAck = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_PREV_LAST_ACK"
    $healthHistoryLastSeq = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_LAST_SEQ"
    $healthHistoryLastCode = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_LAST_CODE"
    $healthHistoryLastAck = Extract-IntValue -Text $gdbText -Name "HEALTH_HISTORY_LAST_ACK"

    if ($null -in @($ack, $lastOpcode, $lastResult, $ticks, $commandHistoryLen, $commandHistoryOverflow,
            $commandHistoryHead, $commandHistoryFirstSeq, $commandHistoryFirstArg0, $commandHistoryLastSeq,
            $commandHistoryLastArg0, $healthHistoryLen, $healthHistoryOverflow, $healthHistoryHead,
            $healthHistoryFirstSeq, $healthHistoryFirstCode, $healthHistoryFirstAck, $healthHistoryPrevLastSeq,
            $healthHistoryPrevLastCode, $healthHistoryPrevLastAck, $healthHistoryLastSeq, $healthHistoryLastCode,
            $healthHistoryLastAck)) {
        throw "Probe output was missing one or more expected values."
    }

    if ($ack -ne $expectedFinalAck) { throw "Expected final ACK $expectedFinalAck, got $ack" }
    if ($lastOpcode -ne $setHealthCodeOpcode) { throw "Expected final opcode $setHealthCodeOpcode, got $lastOpcode" }
    if ($lastResult -ne 0) { throw "Expected final result 0, got $lastResult" }
    if ($ticks -lt $expectedFinalTickFloor) { throw "Expected ticks >= $expectedFinalTickFloor, got $ticks" }
    if ($commandHistoryLen -ne $commandHistoryCapacity) { throw "Expected command history len $commandHistoryCapacity, got $commandHistoryLen" }
    if ($commandHistoryOverflow -ne $expectedCommandHistoryOverflow) { throw "Expected command history overflow $expectedCommandHistoryOverflow, got $commandHistoryOverflow" }
    if ($commandHistoryHead -ne $expectedCommandHead) { throw "Expected command history head $expectedCommandHead, got $commandHistoryHead" }
    if ($commandHistoryFirstSeq -ne $expectedCommandFirstSeq) { throw "Expected first command seq $expectedCommandFirstSeq, got $commandHistoryFirstSeq" }
    if ($commandHistoryFirstArg0 -ne $expectedCommandFirstArg0) { throw "Expected first command arg0 $expectedCommandFirstArg0, got $commandHistoryFirstArg0" }
    if ($commandHistoryLastSeq -ne $expectedCommandLastSeq) { throw "Expected last command seq $expectedCommandLastSeq, got $commandHistoryLastSeq" }
    if ($commandHistoryLastArg0 -ne $expectedCommandLastArg0) { throw "Expected last command arg0 $expectedCommandLastArg0, got $commandHistoryLastArg0" }
    if ($healthHistoryLen -ne $healthHistoryCapacity) { throw "Expected health history len $healthHistoryCapacity, got $healthHistoryLen" }
    if ($healthHistoryOverflow -ne $expectedHealthHistoryOverflow) { throw "Expected health history overflow $expectedHealthHistoryOverflow, got $healthHistoryOverflow" }
    if ($healthHistoryHead -ne $expectedHealthHead) { throw "Expected health history head $expectedHealthHead, got $healthHistoryHead" }
    if ($healthHistoryFirstSeq -ne $expectedHealthFirstSeq) { throw "Expected first health seq $expectedHealthFirstSeq, got $healthHistoryFirstSeq" }
    if ($healthHistoryFirstCode -ne $expectedHealthFirstCode) { throw "Expected first health code $expectedHealthFirstCode, got $healthHistoryFirstCode" }
    if ($healthHistoryFirstAck -ne $expectedHealthFirstAck) { throw "Expected first health ack $expectedHealthFirstAck, got $healthHistoryFirstAck" }
    if ($healthHistoryPrevLastSeq -ne $expectedHealthPrevLastSeq) { throw "Expected previous last health seq $expectedHealthPrevLastSeq, got $healthHistoryPrevLastSeq" }
    if ($healthHistoryPrevLastCode -ne $expectedHealthPrevLastCode) { throw "Expected previous last health code $expectedHealthPrevLastCode, got $healthHistoryPrevLastCode" }
    if ($healthHistoryPrevLastAck -ne $expectedHealthPrevLastAck) { throw "Expected previous last health ack $expectedHealthPrevLastAck, got $healthHistoryPrevLastAck" }
    if ($healthHistoryLastSeq -ne $expectedHealthLastSeq) { throw "Expected last health seq $expectedHealthLastSeq, got $healthHistoryLastSeq" }
    if ($healthHistoryLastCode -ne $expectedHealthLastCode) { throw "Expected last health code $expectedHealthLastCode, got $healthHistoryLastCode" }
    if ($healthHistoryLastAck -ne $expectedHealthLastAck) { throw "Expected last health ack $expectedHealthLastAck, got $healthHistoryLastAck" }

    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_COMMAND_HEALTH_HISTORY_PROBE=pass"
} finally {
    if ($null -ne $qemuProcess -and -not $qemuProcess.HasExited) {
        Stop-Process -Id $qemuProcess.Id -Force
        $qemuProcess.WaitForExit()
    }
}
