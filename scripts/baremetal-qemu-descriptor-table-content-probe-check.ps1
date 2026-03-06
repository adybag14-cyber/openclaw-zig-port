param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 1249
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$prerequisiteScript = Join-Path $PSScriptRoot "baremetal-qemu-descriptor-bootdiag-probe-check.ps1"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-descriptor-bootdiag-probe.elf"
$gdbScript = Join-Path $releaseDir "qemu-descriptor-table-content-probe.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-descriptor-table-content-probe.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-descriptor-table-content-probe.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-descriptor-table-content-probe.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-descriptor-table-content-probe.qemu.stderr.log"

$reinitDescriptorTablesOpcode = 9
$loadDescriptorTablesOpcode = 10

$statusTicksOffset = 8
$statusCommandSeqAckOffset = 28
$statusLastCommandOpcodeOffset = 32
$statusLastCommandResultOffset = 34

$commandOpcodeOffset = 6
$commandSeqOffset = 8
$commandArg0Offset = 16
$commandArg1Offset = 24

$interruptDescriptorReadyOffset = 0
$interruptDescriptorLoadedOffset = 1
$interruptLoadAttemptsOffset = 4
$interruptLoadSuccessesOffset = 8
$interruptDescriptorInitCountOffset = 12

$descriptorPointerLimitOffset = 0
$descriptorPointerBaseOffset = 8
$gdtEntryStride = 8
$gdtLimitLowOffset = 0
$gdtAccessOffset = 5
$gdtGranularityOffset = 6
$idtEntryStride = 16
$idtOffsetLowOffset = 0
$idtSelectorOffset = 2
$idtIstOffset = 4
$idtTypeAttrOffset = 5
$idtOffsetMidOffset = 6
$idtOffsetHighOffset = 8
$idtZeroOffset = 12

$expectedGdtrLimit = 63
$expectedIdtrLimit = 4095
$expectedSelector = 8
$expectedTypeAttr = 142
$expectedGdtLimitLow = 65535
$expectedGdtCodeAccess = 154
$expectedGdtDataAccess = 146
$expectedGdtGranularity = 175

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
    param([switch] $Force)
    if ($SkipBuild -and $Force) {
        throw "Descriptor-table content probe artifact is stale or missing and -SkipBuild was supplied."
    }
    if ($SkipBuild -and -not (Test-Path $artifact)) {
        throw "Descriptor-table content probe prerequisite artifact not found at $artifact and -SkipBuild was supplied."
    }
    if ($SkipBuild -and -not $Force) { return }
    if (-not (Test-Path $prerequisiteScript)) {
        throw "Prerequisite script not found: $prerequisiteScript"
    }
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
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE=skipped"
    exit 0
}
if ($null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE=skipped"
    exit 0
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE=skipped"
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
$gdtrAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.gdtr$' -SymbolName "baremetal.x86_bootstrap.gdtr"
$idtrAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.idtr$' -SymbolName "baremetal.x86_bootstrap.idtr"
$gdtAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.gdt$' -SymbolName "baremetal.x86_bootstrap.gdt"
$idtAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.x86_bootstrap\.idt$' -SymbolName "baremetal.x86_bootstrap.idt"
$interruptStubAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal\.x86_bootstrap\.oc_interrupt_stub$' -SymbolName "baremetal.x86_bootstrap.oc_interrupt_stub"
$artifactForGdb = $artifact.Replace('\', '/')
$gdtAddressExpected = [Convert]::ToInt64($gdtAddress, 16)
$idtAddressExpected = [Convert]::ToInt64($idtAddress, 16)
$interruptStubAddressExpected = [Convert]::ToInt64($interruptStubAddress, 16)
if (Test-Path $gdbStdout) { Remove-Item -Force $gdbStdout }
if (Test-Path $gdbStderr) { Remove-Item -Force $gdbStderr }
if (Test-Path $qemuStdout) { Remove-Item -Force $qemuStdout }
if (Test-Path $qemuStderr) { Remove-Item -Force $qemuStderr }

@"
set pagination off
set confirm off
set `$stage = 0
set `$descriptor_ready_before = 0
set `$descriptor_loaded_before = 0
set `$load_attempts_before = 0
set `$load_successes_before = 0
set `$descriptor_init_before = 0
set `$descriptor_ready_after_reinit = 0
set `$descriptor_loaded_after_reinit = 0
set `$descriptor_init_after_reinit = 0
set `$gdtr_limit = 0
set `$gdtr_base = 0
set `$idtr_limit = 0
set `$idtr_base = 0
set `$gdt1_limit_low = 0
set `$gdt1_access = 0
set `$gdt1_granularity = 0
set `$gdt2_limit_low = 0
set `$gdt2_access = 0
set `$gdt2_granularity = 0
set `$idt0_selector = 0
set `$idt0_ist = 0
set `$idt0_type_attr = 0
set `$idt0_zero = 0
set `$idt0_handler_addr = 0
set `$idt255_selector = 0
set `$idt255_ist = 0
set `$idt255_type_attr = 0
set `$idt255_zero = 0
set `$idt255_handler_addr = 0
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
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 0 && *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset) == 1 && *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset) == 1
    set `$descriptor_ready_before = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset)
    set `$descriptor_loaded_before = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset)
    set `$load_attempts_before = *(unsigned int*)(0x$interruptStateAddress+$interruptLoadAttemptsOffset)
    set `$load_successes_before = *(unsigned int*)(0x$interruptStateAddress+$interruptLoadSuccessesOffset)
    set `$descriptor_init_before = *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $reinitDescriptorTablesOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 1
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 1
  end
  continue
end
if `$stage == 1
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 1 && *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset) == (`$descriptor_init_before + 1)
    set `$descriptor_ready_after_reinit = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset)
    set `$descriptor_loaded_after_reinit = *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset)
    set `$descriptor_init_after_reinit = *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset)
    set `$gdtr_limit = *(unsigned short*)(0x$gdtrAddress+$descriptorPointerLimitOffset)
    set `$gdtr_base = *(unsigned long long*)(0x$gdtrAddress+$descriptorPointerBaseOffset)
    set `$idtr_limit = *(unsigned short*)(0x$idtrAddress+$descriptorPointerLimitOffset)
    set `$idtr_base = *(unsigned long long*)(0x$idtrAddress+$descriptorPointerBaseOffset)
    set `$gdt1_limit_low = *(unsigned short*)(0x$gdtAddress+($gdtEntryStride*1)+$gdtLimitLowOffset)
    set `$gdt1_access = *(unsigned char*)(0x$gdtAddress+($gdtEntryStride*1)+$gdtAccessOffset)
    set `$gdt1_granularity = *(unsigned char*)(0x$gdtAddress+($gdtEntryStride*1)+$gdtGranularityOffset)
    set `$gdt2_limit_low = *(unsigned short*)(0x$gdtAddress+($gdtEntryStride*2)+$gdtLimitLowOffset)
    set `$gdt2_access = *(unsigned char*)(0x$gdtAddress+($gdtEntryStride*2)+$gdtAccessOffset)
    set `$gdt2_granularity = *(unsigned char*)(0x$gdtAddress+($gdtEntryStride*2)+$gdtGranularityOffset)
    set `$idt0_selector = *(unsigned short*)(0x$idtAddress+$idtSelectorOffset)
    set `$idt0_ist = *(unsigned char*)(0x$idtAddress+$idtIstOffset)
    set `$idt0_type_attr = *(unsigned char*)(0x$idtAddress+$idtTypeAttrOffset)
    set `$idt0_zero = *(unsigned int*)(0x$idtAddress+$idtZeroOffset)
    set `$idt0_handler_addr = *(unsigned short*)(0x$idtAddress+$idtOffsetLowOffset)
    set `$idt0_handler_addr = `$idt0_handler_addr | ((unsigned long long)(*(unsigned short*)(0x$idtAddress+$idtOffsetMidOffset)) << 16)
    set `$idt0_handler_addr = `$idt0_handler_addr | ((unsigned long long)(*(unsigned int*)(0x$idtAddress+$idtOffsetHighOffset)) << 32)
    set `$idt255_selector = *(unsigned short*)(0x$idtAddress+($idtEntryStride*255)+$idtSelectorOffset)
    set `$idt255_ist = *(unsigned char*)(0x$idtAddress+($idtEntryStride*255)+$idtIstOffset)
    set `$idt255_type_attr = *(unsigned char*)(0x$idtAddress+($idtEntryStride*255)+$idtTypeAttrOffset)
    set `$idt255_zero = *(unsigned int*)(0x$idtAddress+($idtEntryStride*255)+$idtZeroOffset)
    set `$idt255_handler_addr = *(unsigned short*)(0x$idtAddress+($idtEntryStride*255)+$idtOffsetLowOffset)
    set `$idt255_handler_addr = `$idt255_handler_addr | ((unsigned long long)(*(unsigned short*)(0x$idtAddress+($idtEntryStride*255)+$idtOffsetMidOffset)) << 16)
    set `$idt255_handler_addr = `$idt255_handler_addr | ((unsigned long long)(*(unsigned int*)(0x$idtAddress+($idtEntryStride*255)+$idtOffsetHighOffset)) << 32)
    set *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset) = $loadDescriptorTablesOpcode
    set *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset) = 2
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg0Offset) = 0
    set *(unsigned long long*)(0x$commandMailboxAddress+$commandArg1Offset) = 0
    set `$stage = 2
  end
  continue
end
if `$stage == 2
  if *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset) == 2 && *(unsigned int*)(0x$interruptStateAddress+$interruptLoadAttemptsOffset) == (`$load_attempts_before + 1) && *(unsigned int*)(0x$interruptStateAddress+$interruptLoadSuccessesOffset) == (`$load_successes_before + 1)
    printf "AFTER_DESCRIPTOR_TABLE_CONTENT\n"
    printf "ACK=%u\n", *(unsigned int*)(0x$statusAddress+$statusCommandSeqAckOffset)
    printf "LAST_OPCODE=%u\n", *(unsigned short*)(0x$statusAddress+$statusLastCommandOpcodeOffset)
    printf "LAST_RESULT=%d\n", *(short*)(0x$statusAddress+$statusLastCommandResultOffset)
    printf "TICKS=%llu\n", *(unsigned long long*)(0x$statusAddress+$statusTicksOffset)
    printf "MAILBOX_OPCODE=%u\n", *(unsigned short*)(0x$commandMailboxAddress+$commandOpcodeOffset)
    printf "MAILBOX_SEQ=%u\n", *(unsigned int*)(0x$commandMailboxAddress+$commandSeqOffset)
    printf "DESCRIPTOR_READY_BEFORE=%u\n", `$descriptor_ready_before
    printf "DESCRIPTOR_LOADED_BEFORE=%u\n", `$descriptor_loaded_before
    printf "LOAD_ATTEMPTS_BEFORE=%u\n", `$load_attempts_before
    printf "LOAD_SUCCESSES_BEFORE=%u\n", `$load_successes_before
    printf "DESCRIPTOR_INIT_BEFORE=%u\n", `$descriptor_init_before
    printf "DESCRIPTOR_READY_AFTER_REINIT=%u\n", `$descriptor_ready_after_reinit
    printf "DESCRIPTOR_LOADED_AFTER_REINIT=%u\n", `$descriptor_loaded_after_reinit
    printf "DESCRIPTOR_INIT_AFTER_REINIT=%u\n", `$descriptor_init_after_reinit
    printf "DESCRIPTOR_READY_FINAL=%u\n", *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorReadyOffset)
    printf "DESCRIPTOR_LOADED_FINAL=%u\n", *(unsigned char*)(0x$interruptStateAddress+$interruptDescriptorLoadedOffset)
    printf "LOAD_ATTEMPTS_FINAL=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptLoadAttemptsOffset)
    printf "LOAD_SUCCESSES_FINAL=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptLoadSuccessesOffset)
    printf "DESCRIPTOR_INIT_FINAL=%u\n", *(unsigned int*)(0x$interruptStateAddress+$interruptDescriptorInitCountOffset)
    printf "GDTR_LIMIT=%u\n", `$gdtr_limit
    printf "GDTR_BASE=%llu\n", `$gdtr_base
    printf "IDTR_LIMIT=%u\n", `$idtr_limit
    printf "IDTR_BASE=%llu\n", `$idtr_base
    printf "GDT_SYMBOL=%llu\n", (unsigned long long)0x$gdtAddress
    printf "IDT_SYMBOL=%llu\n", (unsigned long long)0x$idtAddress
    printf "INTERRUPT_STUB_SYMBOL=%llu\n", (unsigned long long)0x$interruptStubAddress
    printf "GDT1_LIMIT_LOW=%u\n", `$gdt1_limit_low
    printf "GDT1_ACCESS=%u\n", `$gdt1_access
    printf "GDT1_GRANULARITY=%u\n", `$gdt1_granularity
    printf "GDT2_LIMIT_LOW=%u\n", `$gdt2_limit_low
    printf "GDT2_ACCESS=%u\n", `$gdt2_access
    printf "GDT2_GRANULARITY=%u\n", `$gdt2_granularity
    printf "IDT0_SELECTOR=%u\n", `$idt0_selector
    printf "IDT0_IST=%u\n", `$idt0_ist
    printf "IDT0_TYPE_ATTR=%u\n", `$idt0_type_attr
    printf "IDT0_ZERO=%u\n", `$idt0_zero
    printf "IDT0_HANDLER_ADDR=%llu\n", `$idt0_handler_addr
    printf "IDT255_SELECTOR=%u\n", `$idt255_selector
    printf "IDT255_IST=%u\n", `$idt255_ist
    printf "IDT255_TYPE_ATTR=%u\n", `$idt255_type_attr
    printf "IDT255_ZERO=%u\n", `$idt255_zero
    printf "IDT255_HANDLER_ADDR=%llu\n", `$idt255_handler_addr
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
$hitStart = $false
$hitAfterDescriptorTableContent = $false
$ack = $null
$lastOpcode = $null
$lastResult = $null
$ticks = $null
$mailboxOpcode = $null
$mailboxSeq = $null
$descriptorReadyBefore = $null
$descriptorLoadedBefore = $null
$loadAttemptsBefore = $null
$loadSuccessesBefore = $null
$descriptorInitBefore = $null
$descriptorReadyAfterReinit = $null
$descriptorLoadedAfterReinit = $null
$descriptorInitAfterReinit = $null
$descriptorReadyFinal = $null
$descriptorLoadedFinal = $null
$loadAttemptsFinal = $null
$loadSuccessesFinal = $null
$descriptorInitFinal = $null
$gdtrLimit = $null
$gdtrBase = $null
$idtrLimit = $null
$idtrBase = $null
$gdtSymbol = $null
$idtSymbol = $null
$interruptStubSymbol = $null
$gdt1LimitLow = $null
$gdt1Access = $null
$gdt1Granularity = $null
$gdt2LimitLow = $null
$gdt2Access = $null
$gdt2Granularity = $null
$idt0Selector = $null
$idt0Ist = $null
$idt0TypeAttr = $null
$idt0Zero = $null
$idt0HandlerAddr = $null
$idt255Selector = $null
$idt255Ist = $null
$idt255TypeAttr = $null
$idt255Zero = $null
$idt255HandlerAddr = $null

if (Test-Path $gdbStdout) {
    $out = Get-Content -Raw $gdbStdout
    $hitStart = $out -match "HIT_START"
    $hitAfterDescriptorTableContent = $out -match "AFTER_DESCRIPTOR_TABLE_CONTENT"
    $ack = Extract-IntValue -Text $out -Name "ACK"
    $lastOpcode = Extract-IntValue -Text $out -Name "LAST_OPCODE"
    $lastResult = Extract-IntValue -Text $out -Name "LAST_RESULT"
    $ticks = Extract-IntValue -Text $out -Name "TICKS"
    $mailboxOpcode = Extract-IntValue -Text $out -Name "MAILBOX_OPCODE"
    $mailboxSeq = Extract-IntValue -Text $out -Name "MAILBOX_SEQ"
    $descriptorReadyBefore = Extract-IntValue -Text $out -Name "DESCRIPTOR_READY_BEFORE"
    $descriptorLoadedBefore = Extract-IntValue -Text $out -Name "DESCRIPTOR_LOADED_BEFORE"
    $loadAttemptsBefore = Extract-IntValue -Text $out -Name "LOAD_ATTEMPTS_BEFORE"
    $loadSuccessesBefore = Extract-IntValue -Text $out -Name "LOAD_SUCCESSES_BEFORE"
    $descriptorInitBefore = Extract-IntValue -Text $out -Name "DESCRIPTOR_INIT_BEFORE"
    $descriptorReadyAfterReinit = Extract-IntValue -Text $out -Name "DESCRIPTOR_READY_AFTER_REINIT"
    $descriptorLoadedAfterReinit = Extract-IntValue -Text $out -Name "DESCRIPTOR_LOADED_AFTER_REINIT"
    $descriptorInitAfterReinit = Extract-IntValue -Text $out -Name "DESCRIPTOR_INIT_AFTER_REINIT"
    $descriptorReadyFinal = Extract-IntValue -Text $out -Name "DESCRIPTOR_READY_FINAL"
    $descriptorLoadedFinal = Extract-IntValue -Text $out -Name "DESCRIPTOR_LOADED_FINAL"
    $loadAttemptsFinal = Extract-IntValue -Text $out -Name "LOAD_ATTEMPTS_FINAL"
    $loadSuccessesFinal = Extract-IntValue -Text $out -Name "LOAD_SUCCESSES_FINAL"
    $descriptorInitFinal = Extract-IntValue -Text $out -Name "DESCRIPTOR_INIT_FINAL"
    $gdtrLimit = Extract-IntValue -Text $out -Name "GDTR_LIMIT"
    $gdtrBase = Extract-IntValue -Text $out -Name "GDTR_BASE"
    $idtrLimit = Extract-IntValue -Text $out -Name "IDTR_LIMIT"
    $idtrBase = Extract-IntValue -Text $out -Name "IDTR_BASE"
    $gdtSymbol = Extract-IntValue -Text $out -Name "GDT_SYMBOL"
    $idtSymbol = Extract-IntValue -Text $out -Name "IDT_SYMBOL"
    $interruptStubSymbol = Extract-IntValue -Text $out -Name "INTERRUPT_STUB_SYMBOL"
    $gdt1LimitLow = Extract-IntValue -Text $out -Name "GDT1_LIMIT_LOW"
    $gdt1Access = Extract-IntValue -Text $out -Name "GDT1_ACCESS"
    $gdt1Granularity = Extract-IntValue -Text $out -Name "GDT1_GRANULARITY"
    $gdt2LimitLow = Extract-IntValue -Text $out -Name "GDT2_LIMIT_LOW"
    $gdt2Access = Extract-IntValue -Text $out -Name "GDT2_ACCESS"
    $gdt2Granularity = Extract-IntValue -Text $out -Name "GDT2_GRANULARITY"
    $idt0Selector = Extract-IntValue -Text $out -Name "IDT0_SELECTOR"
    $idt0Ist = Extract-IntValue -Text $out -Name "IDT0_IST"
    $idt0TypeAttr = Extract-IntValue -Text $out -Name "IDT0_TYPE_ATTR"
    $idt0Zero = Extract-IntValue -Text $out -Name "IDT0_ZERO"
    $idt0HandlerAddr = Extract-IntValue -Text $out -Name "IDT0_HANDLER_ADDR"
    $idt255Selector = Extract-IntValue -Text $out -Name "IDT255_SELECTOR"
    $idt255Ist = Extract-IntValue -Text $out -Name "IDT255_IST"
    $idt255TypeAttr = Extract-IntValue -Text $out -Name "IDT255_TYPE_ATTR"
    $idt255Zero = Extract-IntValue -Text $out -Name "IDT255_ZERO"
    $idt255HandlerAddr = Extract-IntValue -Text $out -Name "IDT255_HANDLER_ADDR"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_GDTR_ADDR=0x$gdtrAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_IDTR_ADDR=0x$idtrAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_GDT_ADDR=0x$gdtAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_IDT_ADDR=0x$idtAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_INTERRUPT_STUB_ADDR=0x$interruptStubAddress"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_HIT_AFTER_DESCRIPTOR_TABLE_CONTENT=$hitAfterDescriptorTableContent"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_ACK=$ack"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_LAST_OPCODE=$lastOpcode"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_LAST_RESULT=$lastResult"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_TICKS=$ticks"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_GDTR_LIMIT=$gdtrLimit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_IDTR_LIMIT=$idtrLimit"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_GDT1_ACCESS=$gdt1Access"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_GDT2_ACCESS=$gdt2Access"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_IDT0_TYPE_ATTR=$idt0TypeAttr"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_IDT255_TYPE_ATTR=$idt255TypeAttr"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_GDB_STDOUT=$gdbStdout"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_GDB_STDERR=$gdbStderr"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_QEMU_STDOUT=$qemuStdout"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_QEMU_STDERR=$qemuStderr"
Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE_TIMED_OUT=$timedOut"

$pass = (
    $hitStart -and
    $hitAfterDescriptorTableContent -and
    (-not $timedOut) -and
    $ack -eq 2 -and
    $lastOpcode -eq $loadDescriptorTablesOpcode -and
    $lastResult -eq 0 -and
    $ticks -gt 0 -and
    $mailboxOpcode -eq $loadDescriptorTablesOpcode -and
    $mailboxSeq -eq 2 -and
    $descriptorReadyBefore -eq 1 -and
    $descriptorLoadedBefore -eq 1 -and
    $loadAttemptsBefore -ge 1 -and
    $loadSuccessesBefore -ge 1 -and
    $descriptorInitBefore -ge 1 -and
    $descriptorReadyAfterReinit -eq 1 -and
    $descriptorLoadedAfterReinit -eq 1 -and
    $descriptorInitAfterReinit -eq ($descriptorInitBefore + 1) -and
    $descriptorReadyFinal -eq 1 -and
    $descriptorLoadedFinal -eq 1 -and
    $loadAttemptsFinal -eq ($loadAttemptsBefore + 1) -and
    $loadSuccessesFinal -eq ($loadSuccessesBefore + 1) -and
    $descriptorInitFinal -eq $descriptorInitAfterReinit -and
    $gdtrLimit -eq $expectedGdtrLimit -and
    $idtrLimit -eq $expectedIdtrLimit -and
    $gdtrBase -eq $gdtAddressExpected -and
    $idtrBase -eq $idtAddressExpected -and
    $gdtSymbol -eq $gdtAddressExpected -and
    $idtSymbol -eq $idtAddressExpected -and
    $interruptStubSymbol -eq $interruptStubAddressExpected -and
    $gdt1LimitLow -eq $expectedGdtLimitLow -and
    $gdt1Access -eq $expectedGdtCodeAccess -and
    $gdt1Granularity -eq $expectedGdtGranularity -and
    $gdt2LimitLow -eq $expectedGdtLimitLow -and
    $gdt2Access -eq $expectedGdtDataAccess -and
    $gdt2Granularity -eq $expectedGdtGranularity -and
    $idt0Selector -eq $expectedSelector -and
    $idt0Ist -eq 0 -and
    $idt0TypeAttr -eq $expectedTypeAttr -and
    $idt0Zero -eq 0 -and
    $idt0HandlerAddr -eq $interruptStubAddressExpected -and
    $idt255Selector -eq $expectedSelector -and
    $idt255Ist -eq 0 -and
    $idt255TypeAttr -eq $expectedTypeAttr -and
    $idt255Zero -eq 0 -and
    $idt255HandlerAddr -eq $interruptStubAddressExpected
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_DESCRIPTOR_TABLE_CONTENT_PROBE=fail"
if (Test-Path $gdbStdout) { Get-Content -Path $gdbStdout -Tail 160 }
if (Test-Path $gdbStderr) { Get-Content -Path $gdbStderr -Tail 160 }
if (Test-Path $qemuStderr) { Get-Content -Path $qemuStderr -Tail 160 }
exit 1
