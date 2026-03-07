param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1282
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-descriptor-bootdiag-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-vector-history-clear-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-vector-history-clear-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-vector-history-clear-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-vector-history-clear-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-vector-history-clear-probe.qemu.stderr.log"

$triggerInterruptOpcode = 7
$resetInterruptCountersOpcode = 8
$resetExceptionCountersOpcode = 11
$triggerExceptionOpcode = 12
$clearExceptionHistoryOpcode = 13
$clearInterruptHistoryOpcode = 14

$interruptVector = 200
$exceptionVector = 13
$exceptionCode = 51966

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$interruptStateInterruptCountOffset = 16
$interruptStateExceptionCountOffset = 32
$interruptStateExceptionHistoryLenOffset = 48
$interruptStateExceptionHistoryOverflowOffset = 52
$interruptStateInterruptHistoryLenOffset = 56
$interruptStateInterruptHistoryOverflowOffset = 60

$interruptEventStride = 32
$interruptEventSeqOffset = 0
$interruptEventVectorOffset = 4
$interruptEventIsExceptionOffset = 5
$interruptEventCodeOffset = 8

$exceptionEventStride = 32
$exceptionEventSeqOffset = 0
$exceptionEventVectorOffset = 4
$exceptionEventCodeOffset = 8

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
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Vector history clear prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
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
    Write-Output "BAREMETAL_QEMU_VECTOR_HISTORY_CLEAR_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_VECTOR_HISTORY_CLEAR_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_VECTOR_HISTORY_CLEAR_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_VECTOR_HISTORY_CLEAR_PROBE=skipped"
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
$interruptStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_state$' -SymbolName "baremetal.x86_bootstrap.interrupt_state"
$interruptHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.interrupt_history$' -SymbolName "baremetal.x86_bootstrap.interrupt_history"
$exceptionHistoryAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.exception_history$' -SymbolName "baremetal.x86_bootstrap.exception_history"

$artifactForGdb = $artifact.Replace('\', '/')
if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$pre_interrupt0_seq = 0
set `$pre_interrupt0_vector = 0
set `$pre_interrupt0_is_exception = 0
set `$pre_interrupt0_code = 0
set `$pre_interrupt1_seq = 0
set `$pre_interrupt1_vector = 0
set `$pre_interrupt1_is_exception = 0
set `$pre_interrupt1_code = 0
set `$pre_exception0_seq = 0
set `$pre_exception0_vector = 0
set `$pre_exception0_code = 0
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
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetInterruptCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 1
  end
  continue
end
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $clearInterruptHistoryOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $resetExceptionCountersOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $clearExceptionHistoryOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 4
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 4
  end
  continue
end
if `$stage == 4
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 4 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset) == 0
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerInterruptOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $interruptVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 5
  end
  continue
end
if `$stage == 5
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 5 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset) == 1 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $triggerExceptionOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = $exceptionVector
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = $exceptionCode
    set `$stage = 6
  end
  continue
end
if `$stage == 6
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 6 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset) == 2 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset) == 1 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset) == 2 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset) == 1
    set `$pre_interrupt0_seq = *(unsigned int*)(0x$interruptHistoryAddress + (0 * $interruptEventStride) + $interruptEventSeqOffset)
    set `$pre_interrupt0_vector = *(unsigned char*)(0x$interruptHistoryAddress + (0 * $interruptEventStride) + $interruptEventVectorOffset)
    set `$pre_interrupt0_is_exception = *(unsigned char*)(0x$interruptHistoryAddress + (0 * $interruptEventStride) + $interruptEventIsExceptionOffset)
    set `$pre_interrupt0_code = *(unsigned long long*)(0x$interruptHistoryAddress + (0 * $interruptEventStride) + $interruptEventCodeOffset)
    set `$pre_interrupt1_seq = *(unsigned int*)(0x$interruptHistoryAddress + (1 * $interruptEventStride) + $interruptEventSeqOffset)
    set `$pre_interrupt1_vector = *(unsigned char*)(0x$interruptHistoryAddress + (1 * $interruptEventStride) + $interruptEventVectorOffset)
    set `$pre_interrupt1_is_exception = *(unsigned char*)(0x$interruptHistoryAddress + (1 * $interruptEventStride) + $interruptEventIsExceptionOffset)
    set `$pre_interrupt1_code = *(unsigned long long*)(0x$interruptHistoryAddress + (1 * $interruptEventStride) + $interruptEventCodeOffset)
    set `$pre_exception0_seq = *(unsigned int*)(0x$exceptionHistoryAddress + (0 * $exceptionEventStride) + $exceptionEventSeqOffset)
    set `$pre_exception0_vector = *(unsigned char*)(0x$exceptionHistoryAddress + (0 * $exceptionEventStride) + $exceptionEventVectorOffset)
    set `$pre_exception0_code = *(unsigned long long*)(0x$exceptionHistoryAddress + (0 * $exceptionEventStride) + $exceptionEventCodeOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $clearInterruptHistoryOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 7
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 7
  end
  continue
end
if `$stage == 7
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 7 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset) == 0 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryOverflowOffset) == 0 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset) == 2 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset) == 1
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $clearExceptionHistoryOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 8
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 8
  end
  continue
end
if `$stage == 8
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 8 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset) == 0 && *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryOverflowOffset) == 0 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset) == 2 && *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset) == 1
    printf "HIT_AFTER_VECTOR_HISTORY_CLEAR_PROBE\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "PRE_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
    printf "PRE_EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset)
    printf "PRE_INTERRUPT_HISTORY_LEN=2\n"
    printf "PRE_EXCEPTION_HISTORY_LEN=1\n"
    printf "PRE_INTERRUPT0_SEQ=%u\n", `$pre_interrupt0_seq
    printf "PRE_INTERRUPT0_VECTOR=%u\n", `$pre_interrupt0_vector
    printf "PRE_INTERRUPT0_IS_EXCEPTION=%u\n", `$pre_interrupt0_is_exception
    printf "PRE_INTERRUPT0_CODE=%llu\n", `$pre_interrupt0_code
    printf "PRE_INTERRUPT1_SEQ=%u\n", `$pre_interrupt1_seq
    printf "PRE_INTERRUPT1_VECTOR=%u\n", `$pre_interrupt1_vector
    printf "PRE_INTERRUPT1_IS_EXCEPTION=%u\n", `$pre_interrupt1_is_exception
    printf "PRE_INTERRUPT1_CODE=%llu\n", `$pre_interrupt1_code
    printf "PRE_EXCEPTION0_SEQ=%u\n", `$pre_exception0_seq
    printf "PRE_EXCEPTION0_VECTOR=%u\n", `$pre_exception0_vector
    printf "PRE_EXCEPTION0_CODE=%llu\n", `$pre_exception0_code
    printf "POST_INTERRUPT_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryLenOffset)
    printf "POST_INTERRUPT_HISTORY_OVERFLOW=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateInterruptHistoryOverflowOffset)
    printf "POST_EXCEPTION_HISTORY_LEN_AFTER_INTERRUPT_CLEAR=1\n"
    printf "POST_EXCEPTION_HISTORY_LEN=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryLenOffset)
    printf "POST_EXCEPTION_HISTORY_OVERFLOW=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptStateExceptionHistoryOverflowOffset)
    printf "FINAL_INTERRUPT_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateInterruptCountOffset)
    printf "FINAL_EXCEPTION_COUNT=%llu\n", *(unsigned long long*)(0x$interruptStateAddress+$interruptStateExceptionCountOffset)
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

    if ($gdbText -notmatch 'HIT_START' -or $gdbText -notmatch 'HIT_AFTER_VECTOR_HISTORY_CLEAR_PROBE') {
        throw "Probe did not reach all expected stages."
    }

    $ack = Extract-IntValue -Text $gdbText -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $gdbText -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $gdbText -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $gdbText -Name "TICKS"
    $preInterruptCount = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT_COUNT"
    $preExceptionCount = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION_COUNT"
    $preInterruptHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT_HISTORY_LEN"
    $preExceptionHistoryLen = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION_HISTORY_LEN"
    $preInterrupt0Seq = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT0_SEQ"
    $preInterrupt0Vector = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT0_VECTOR"
    $preInterrupt0IsException = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT0_IS_EXCEPTION"
    $preInterrupt0Code = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT0_CODE"
    $preInterrupt1Seq = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT1_SEQ"
    $preInterrupt1Vector = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT1_VECTOR"
    $preInterrupt1IsException = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT1_IS_EXCEPTION"
    $preInterrupt1Code = Extract-IntValue -Text $gdbText -Name "PRE_INTERRUPT1_CODE"
    $preException0Seq = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION0_SEQ"
    $preException0Vector = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION0_VECTOR"
    $preException0Code = Extract-IntValue -Text $gdbText -Name "PRE_EXCEPTION0_CODE"
    $postInterruptHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_INTERRUPT_HISTORY_LEN"
    $postInterruptHistoryOverflow = Extract-IntValue -Text $gdbText -Name "POST_INTERRUPT_HISTORY_OVERFLOW"
    $postExceptionHistoryLenAfterInterruptClear = Extract-IntValue -Text $gdbText -Name "POST_EXCEPTION_HISTORY_LEN_AFTER_INTERRUPT_CLEAR"
    $postExceptionHistoryLen = Extract-IntValue -Text $gdbText -Name "POST_EXCEPTION_HISTORY_LEN"
    $postExceptionHistoryOverflow = Extract-IntValue -Text $gdbText -Name "POST_EXCEPTION_HISTORY_OVERFLOW"
    $finalInterruptCount = Extract-IntValue -Text $gdbText -Name "FINAL_INTERRUPT_COUNT"
    $finalExceptionCount = Extract-IntValue -Text $gdbText -Name "FINAL_EXCEPTION_COUNT"

    if ($null -in @($ack, $lastOpcode, $lastResult, $ticks, $preInterruptCount, $preExceptionCount,
            $preInterruptHistoryLen, $preExceptionHistoryLen, $preInterrupt0Seq, $preInterrupt0Vector,
            $preInterrupt0IsException, $preInterrupt0Code, $preInterrupt1Seq, $preInterrupt1Vector,
            $preInterrupt1IsException, $preInterrupt1Code, $preException0Seq, $preException0Vector,
            $preException0Code, $postInterruptHistoryLen, $postInterruptHistoryOverflow,
            $postExceptionHistoryLenAfterInterruptClear, $postExceptionHistoryLen, $postExceptionHistoryOverflow,
            $finalInterruptCount, $finalExceptionCount)) {
        throw "Probe output was missing one or more expected values."
    }

    if ($ack -ne 8) { throw "Expected final ACK 8, got $ack" }
    if ($lastOpcode -ne $clearExceptionHistoryOpcode) { throw "Expected final opcode $clearExceptionHistoryOpcode, got $lastOpcode" }
    if ($lastResult -ne 0) { throw "Expected final result 0, got $lastResult" }
    if ($ticks -lt 8) { throw "Expected ticks >= 8, got $ticks" }
    if ($preInterruptCount -ne 2) { throw "Expected pre-clear interrupt count 2, got $preInterruptCount" }
    if ($preExceptionCount -ne 1) { throw "Expected pre-clear exception count 1, got $preExceptionCount" }
    if ($preInterruptHistoryLen -ne 2) { throw "Expected pre-clear interrupt history len 2, got $preInterruptHistoryLen" }
    if ($preExceptionHistoryLen -ne 1) { throw "Expected pre-clear exception history len 1, got $preExceptionHistoryLen" }
    if ($preInterrupt0Seq -ne 1) { throw "Expected first interrupt event seq 1, got $preInterrupt0Seq" }
    if ($preInterrupt0Vector -ne $interruptVector) { throw "Expected first interrupt vector $interruptVector, got $preInterrupt0Vector" }
    if ($preInterrupt0IsException -ne 0) { throw "Expected first interrupt is_exception 0, got $preInterrupt0IsException" }
    if ($preInterrupt0Code -ne 0) { throw "Expected first interrupt code 0, got $preInterrupt0Code" }
    if ($preInterrupt1Seq -ne 2) { throw "Expected second interrupt event seq 2, got $preInterrupt1Seq" }
    if ($preInterrupt1Vector -ne $exceptionVector) { throw "Expected second interrupt vector $exceptionVector, got $preInterrupt1Vector" }
    if ($preInterrupt1IsException -ne 1) { throw "Expected second interrupt is_exception 1, got $preInterrupt1IsException" }
    if ($preInterrupt1Code -ne $exceptionCode) { throw "Expected second interrupt code $exceptionCode, got $preInterrupt1Code" }
    if ($preException0Seq -ne 1) { throw "Expected first exception event seq 1, got $preException0Seq" }
    if ($preException0Vector -ne $exceptionVector) { throw "Expected first exception vector $exceptionVector, got $preException0Vector" }
    if ($preException0Code -ne $exceptionCode) { throw "Expected first exception code $exceptionCode, got $preException0Code" }
    if ($postInterruptHistoryLen -ne 0) { throw "Expected post-clear interrupt history len 0, got $postInterruptHistoryLen" }
    if ($postInterruptHistoryOverflow -ne 0) { throw "Expected post-clear interrupt history overflow 0, got $postInterruptHistoryOverflow" }
    if ($postExceptionHistoryLenAfterInterruptClear -ne 1) { throw "Expected exception history len 1 after interrupt clear, got $postExceptionHistoryLenAfterInterruptClear" }
    if ($postExceptionHistoryLen -ne 0) { throw "Expected final exception history len 0, got $postExceptionHistoryLen" }
    if ($postExceptionHistoryOverflow -ne 0) { throw "Expected final exception history overflow 0, got $postExceptionHistoryOverflow" }
    if ($finalInterruptCount -ne 2) { throw "Expected final interrupt count 2, got $finalInterruptCount" }
    if ($finalExceptionCount -ne 1) { throw "Expected final exception count 1, got $finalExceptionCount" }

    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_VECTOR_HISTORY_CLEAR_PROBE=pass"
} finally {
    if ($null -ne $qemuProcess -and -not $qemuProcess.HasExited) {
        Stop-Process -Id $qemuProcess.Id -Force
        $qemuProcess.WaitForExit()
    }
}
