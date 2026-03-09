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
$gdbScript = Join-Path $releaseDir "qemu-mailbox-header-validation-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-mailbox-header-validation-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-mailbox-header-validation-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-mailbox-header-validation-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-mailbox-header-validation-$runStamp.qemu.stderr.log"

$commandMagic = 0x4f43434d
$apiVersion = 2
$setTickBatchHintOpcode = 6
$resultInvalid = -22
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
    if ($SkipBuild -and -not (Test-Path $artifact)) { throw "Mailbox header validation prerequisite artifact not found at $artifact and -SkipBuild was supplied." }
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
    Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_PROBE=skipped"
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
file $artifactForGdb
handle SIGQUIT nostop noprint pass
target remote :$GdbPort
break *0x$startAddress
commands
silent
printf "HIT_START\n"
set *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset) = 0
set *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset) = $apiVersion
set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 7
set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
set `$stage = 1
continue
end
break *0x$spinPauseAddress
commands
silent
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultInvalid && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == 1
    printf "AFTER_INVALID_MAGIC\n"
    printf "INVALID_MAGIC_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "INVALID_MAGIC_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "INVALID_MAGIC_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "INVALID_MAGIC_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "INVALID_MAGIC_MAILBOX_MAGIC=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset)
    printf "INVALID_MAGIC_MAILBOX_API_VERSION=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset)
    printf "INVALID_MAGIC_MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    set *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset) = $commandMagic
    set *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset) = ($apiVersion + 1)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 9
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultInvalid && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == 1
    printf "AFTER_INVALID_API_VERSION\n"
    printf "INVALID_API_VERSION_ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "INVALID_API_VERSION_LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "INVALID_API_VERSION_LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "INVALID_API_VERSION_TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "INVALID_API_VERSION_MAILBOX_MAGIC=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset)
    printf "INVALID_API_VERSION_MAILBOX_API_VERSION=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset)
    printf "INVALID_API_VERSION_MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    set *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset) = $commandMagic
    set *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset) = $apiVersion
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $setTickBatchHintOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 3
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 5
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 3
  end
  continue
end
if `$stage == 3
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 3 && *(short*)(0x$statusAddress+$statusLastCommandResultOffset) == $resultOk && *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset) == 5
    printf "AFTER_MAILBOX_HEADER_VALIDATION\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "TICK_BATCH_HINT=%u\n", *(unsigned int*)(0x$statusAddress+$statusTickBatchHintOffset)
    printf "MAILBOX_MAGIC=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandMagicOffset)
    printf "MAILBOX_API_VERSION=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandApiVersionOffset)
    printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
    printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
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
$hitAfter = $out -match 'AFTER_MAILBOX_HEADER_VALIDATION'
$ack = Extract-IntValue -Text $out -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $out -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $out -Name 'LAST_RESULT'
$ticks = Extract-IntValue -Text $out -Name 'TICKS'
$tickBatchHint = Extract-IntValue -Text $out -Name 'TICK_BATCH_HINT'
$mailboxMagic = Extract-IntValue -Text $out -Name 'MAILBOX_MAGIC'
$mailboxApiVersion = Extract-IntValue -Text $out -Name 'MAILBOX_API_VERSION'
$mailboxOpcode = Extract-IntValue -Text $out -Name 'MAILBOX_OPCODE'
$mailboxSeq = Extract-IntValue -Text $out -Name 'MAILBOX_SEQ'
$invalidMagicAck = Extract-IntValue -Text $out -Name 'INVALID_MAGIC_ACK'
$invalidMagicLastOpcode = Extract-IntValue -Text $out -Name 'INVALID_MAGIC_LAST_OPCODE'
$invalidMagicLastResult = Extract-IntValue -Text $out -Name 'INVALID_MAGIC_LAST_RESULT'
$invalidMagicTickBatchHint = Extract-IntValue -Text $out -Name 'INVALID_MAGIC_TICK_BATCH_HINT'
$invalidMagicMailboxMagic = Extract-IntValue -Text $out -Name 'INVALID_MAGIC_MAILBOX_MAGIC'
$invalidMagicMailboxApiVersion = Extract-IntValue -Text $out -Name 'INVALID_MAGIC_MAILBOX_API_VERSION'
$invalidMagicMailboxSeq = Extract-IntValue -Text $out -Name 'INVALID_MAGIC_MAILBOX_SEQ'
$invalidApiVersionAck = Extract-IntValue -Text $out -Name 'INVALID_API_VERSION_ACK'
$invalidApiVersionLastOpcode = Extract-IntValue -Text $out -Name 'INVALID_API_VERSION_LAST_OPCODE'
$invalidApiVersionLastResult = Extract-IntValue -Text $out -Name 'INVALID_API_VERSION_LAST_RESULT'
$invalidApiVersionTickBatchHint = Extract-IntValue -Text $out -Name 'INVALID_API_VERSION_TICK_BATCH_HINT'
$invalidApiVersionMailboxMagic = Extract-IntValue -Text $out -Name 'INVALID_API_VERSION_MAILBOX_MAGIC'
$invalidApiVersionMailboxApiVersion = Extract-IntValue -Text $out -Name 'INVALID_API_VERSION_MAILBOX_API_VERSION'
$invalidApiVersionMailboxSeq = Extract-IntValue -Text $out -Name 'INVALID_API_VERSION_MAILBOX_SEQ'

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_TIMED_OUT=$timedOut"
Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_QEMU_STDERR=$qemuStderr"
if ($null -ne $invalidMagicAck) {
    Write-Output "INVALID_MAGIC_ACK=$invalidMagicAck"
    Write-Output "INVALID_MAGIC_LAST_OPCODE=$invalidMagicLastOpcode"
    Write-Output "INVALID_MAGIC_LAST_RESULT=$invalidMagicLastResult"
    Write-Output "INVALID_MAGIC_TICK_BATCH_HINT=$invalidMagicTickBatchHint"
    Write-Output "INVALID_MAGIC_MAILBOX_MAGIC=$invalidMagicMailboxMagic"
    Write-Output "INVALID_MAGIC_MAILBOX_API_VERSION=$invalidMagicMailboxApiVersion"
    Write-Output "INVALID_MAGIC_MAILBOX_SEQ=$invalidMagicMailboxSeq"
}
if ($null -ne $invalidApiVersionAck) {
    Write-Output "INVALID_API_VERSION_ACK=$invalidApiVersionAck"
    Write-Output "INVALID_API_VERSION_LAST_OPCODE=$invalidApiVersionLastOpcode"
    Write-Output "INVALID_API_VERSION_LAST_RESULT=$invalidApiVersionLastResult"
    Write-Output "INVALID_API_VERSION_TICK_BATCH_HINT=$invalidApiVersionTickBatchHint"
    Write-Output "INVALID_API_VERSION_MAILBOX_MAGIC=$invalidApiVersionMailboxMagic"
    Write-Output "INVALID_API_VERSION_MAILBOX_API_VERSION=$invalidApiVersionMailboxApiVersion"
    Write-Output "INVALID_API_VERSION_MAILBOX_SEQ=$invalidApiVersionMailboxSeq"
}
if ($null -ne $ack) {
    Write-Output "ACK=$ack"
    Write-Output "LAST_OPCODE=$lastOpcode"
    Write-Output "LAST_RESULT=$lastResult"
    Write-Output "TICKS=$ticks"
    Write-Output "TICK_BATCH_HINT=$tickBatchHint"
    Write-Output "MAILBOX_MAGIC=$mailboxMagic"
    Write-Output "MAILBOX_API_VERSION=$mailboxApiVersion"
    Write-Output "MAILBOX_OPCODE=$mailboxOpcode"
    Write-Output "MAILBOX_SEQ=$mailboxSeq"
}

$pass = (
    $hitStart -and
    $hitAfter -and
    (-not $timedOut) -and
    $ack -eq 3 -and
    $lastOpcode -eq $setTickBatchHintOpcode -and
    $lastResult -eq $resultOk -and
    $ticks -ge 3 -and
    $tickBatchHint -eq 5 -and
    $mailboxMagic -eq $commandMagic -and
    $mailboxApiVersion -eq $apiVersion -and
    $mailboxOpcode -eq $setTickBatchHintOpcode -and
    $mailboxSeq -eq 3
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_PROBE=pass"
    exit 0
}

Write-Output $out
if ($err) { Write-Output $err }
Write-Output "BAREMETAL_QEMU_MAILBOX_HEADER_VALIDATION_PROBE=fail"
exit 1
