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
$gdbScript = Join-Path $releaseDir "qemu-mailbox-stale-seq-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-mailbox-stale-seq-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-mailbox-stale-seq-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-mailbox-stale-seq-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-mailbox-stale-seq-$runStamp.qemu.stderr.log"

$commandMagic = 0x4f43434d
$apiVersion = 2
$setTickBatchHintOpcode = 6
$resultOk = 0

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34
$statusTickBatchHintOffset = 36

$commandMagicOffset = 0
$commandApiVersionOffset = 4
$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

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
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Mailbox stale-seq prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
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
    Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_PROBE=skipped"
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
$artifactForGdb = $artifact.Replace('\', '/')

@"
set pagination off
set confirm off
set `$stage = 0
set `$replay_last_opcode = 0
set `$replay_last_result = 0
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START\n"
set *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset) = $commandMagic
set *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset) = $apiVersion
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 4
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
set `$stage = 1
continue
end
break *0x$spinPauseAddress
commands
silent
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == 4
    printf "AFTER_FIRST_MAILBOX_COMMAND\n"
    printf "FIRST_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "FIRST_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "FIRST_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "FIRST_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "FIRST_MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    set `$replay_last_opcode = *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    set `$replay_last_result = *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    set *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset) = $commandMagic
    set *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset) = $apiVersion
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == 4 && *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset) == `$replay_last_opcode && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == `$replay_last_result
    printf "AFTER_STALE_REPLAY\n"
    printf "STALE_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "STALE_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "STALE_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "STALE_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "STALE_MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    set *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset) = $commandMagic
    set *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset) = $apiVersion
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 6
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == 6
    printf "AFTER_MAILBOX_STALE_SEQ\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    printf "REPLAY_LAST_OPCODE=%u\n", `$replay_last_opcode
    printf "REPLAY_LAST_RESULT=%d\n", `$replay_last_result
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
$hitAfter = $out -match 'AFTER_MAILBOX_STALE_SEQ'
$ack = Extract-IntValue -Text $out -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $out -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $out -Name 'LAST_RESULT'
$ticks = Extract-IntValue -Text $out -Name 'TICKS'
$tickBatchHint = Extract-IntValue -Text $out -Name 'TICK_BATCH_HINT'
$mailboxSeq = Extract-IntValue -Text $out -Name 'MAILBOX_SEQ'
$replayLastOpcode = Extract-IntValue -Text $out -Name 'REPLAY_LAST_OPCODE'
$replayLastResult = Extract-IntValue -Text $out -Name 'REPLAY_LAST_RESULT'
$firstAck = Extract-IntValue -Text $out -Name 'FIRST_ACK'
$firstLastOpcode = Extract-IntValue -Text $out -Name 'FIRST_LAST_OPCODE'
$firstLastResult = Extract-IntValue -Text $out -Name 'FIRST_LAST_RESULT'
$firstTickBatchHint = Extract-IntValue -Text $out -Name 'FIRST_TICK_BATCH_HINT'
$firstMailboxSeq = Extract-IntValue -Text $out -Name 'FIRST_MAILBOX_SEQ'
$staleAck = Extract-IntValue -Text $out -Name 'STALE_ACK'
$staleLastOpcode = Extract-IntValue -Text $out -Name 'STALE_LAST_OPCODE'
$staleLastResult = Extract-IntValue -Text $out -Name 'STALE_LAST_RESULT'
$staleTickBatchHint = Extract-IntValue -Text $out -Name 'STALE_TICK_BATCH_HINT'
$staleMailboxSeq = Extract-IntValue -Text $out -Name 'STALE_MAILBOX_SEQ'

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_QEMU_STDERR=$qemuStderr"
if ($null -ne $firstAck) {
    Write-Output "FIRST_ACK=$firstAck"
    Write-Output "FIRST_LAST_OPCODE=$firstLastOpcode"
    Write-Output "FIRST_LAST_RESULT=$firstLastResult"
    Write-Output "FIRST_TICK_BATCH_HINT=$firstTickBatchHint"
    Write-Output "FIRST_MAILBOX_SEQ=$firstMailboxSeq"
}
if ($null -ne $staleAck) {
    Write-Output "STALE_ACK=$staleAck"
    Write-Output "STALE_LAST_OPCODE=$staleLastOpcode"
    Write-Output "STALE_LAST_RESULT=$staleLastResult"
    Write-Output "STALE_TICK_BATCH_HINT=$staleTickBatchHint"
    Write-Output "STALE_MAILBOX_SEQ=$staleMailboxSeq"
}
if ($null -ne $ack) {
    Write-Output "ACK=$ack"
    Write-Output "LAST_OPCODE=$lastOpcode"
    Write-Output "LAST_RESULT=$lastResult"
    Write-Output "TICKS=$ticks"
    Write-Output "TICK_BATCH_HINT=$tickBatchHint"
    Write-Output "MAILBOX_SEQ=$mailboxSeq"
    Write-Output "REPLAY_LAST_OPCODE=$replayLastOpcode"
    Write-Output "REPLAY_LAST_RESULT=$replayLastResult"
}

$pass = (
    $hitStart -and
    $hitAfter -and
    (-not $timedOut) -and
    $ack -eq 2 -and
    $lastOpcode -eq $setTickBatchHintOpcode -and
    $lastResult -eq $resultOk -and
    $ticks -ge 2 -and
    $tickBatchHint -eq 6 -and
    $mailboxSeq -eq 2 -and
    $replayLastOpcode -eq $setTickBatchHintOpcode -and
    $replayLastResult -eq $resultOk
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_PROBE=pass"
    exit 0
}

Write-Output $out
if ($err) { Write-Output $err }
Write-Output "BAREMETAL_QEMU_MAILBOX_STALE_SEQ_PROBE=fail"
exit 1
