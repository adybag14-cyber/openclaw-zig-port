param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$consoleMagic = 0x4f43434e
$apiVersion = 2
$consoleBackendVgaText = 1
$expectedCols = 80
$expectedRows = 25
$vgaBufferAddr = 0xB8000
$expectedCellO = 1871
$expectedCellK = 1867

$consoleMagicOffset = 0
$consoleApiVersionOffset = 4
$consoleColsOffset = 6
$consoleRowsOffset = 8
$consoleCursorRowOffset = 10
$consoleCursorColOffset = 12
$consoleBackendOffset = 15
$consoleWriteCountOffset = 20
$consoleScrollCountOffset = 24
$consoleClearCountOffset = 28

function Resolve-ZigExecutable {
    $default = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
    if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) {
        if (-not (Test-Path $env:OPENCLAW_ZIG_BIN)) { throw "OPENCLAW_ZIG_BIN is set but not found: $($env:OPENCLAW_ZIG_BIN)" }
        return $env:OPENCLAW_ZIG_BIN
    }
    $cmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) { return $cmd.Path }
    if (Test-Path $default) { return $default }
    throw "Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure zig is on PATH."
}

function Resolve-PreferredExecutable {
    param([string[]] $Candidates)
    foreach ($name in $Candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Path) { return $cmd.Path }
        if (Test-Path $name) { return (Resolve-Path $name).Path }
    }
    return $null
}

function Resolve-QemuExecutable { return Resolve-PreferredExecutable @("qemu-system-x86_64", "qemu-system-x86_64.exe", "C:\Program Files\qemu\qemu-system-x86_64.exe") }
function Resolve-GdbExecutable { return Resolve-PreferredExecutable @("gdb", "gdb.exe") }
function Resolve-NmExecutable { return Resolve-PreferredExecutable @("llvm-nm", "llvm-nm.exe", "nm", "nm.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\llvm-nm.exe") }
function Resolve-ClangExecutable { return Resolve-PreferredExecutable @("clang", "clang.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\clang.exe") }
function Resolve-LldExecutable { return Resolve-PreferredExecutable @("lld", "lld.exe", "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\lld.exe") }

function Resolve-ZigGlobalCacheDir {
    $candidates = @()
    if ($env:ZIG_GLOBAL_CACHE_DIR) { $candidates += $env:ZIG_GLOBAL_CACHE_DIR }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA "zig") }
    if ($env:XDG_CACHE_HOME) { $candidates += (Join-Path $env:XDG_CACHE_HOME "zig") }
    if ($env:HOME) { $candidates += (Join-Path $env:HOME ".cache/zig") }
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) { return $candidate }
    }
    return (Join-Path $repo ".zig-global-cache")
}

function Resolve-CompilerRtArchive {
    $cacheRoot = Resolve-ZigGlobalCacheDir
    $objRoot = Join-Path $cacheRoot "o"
    if (-not (Test-Path $objRoot)) { return $null }
    $candidate = Get-ChildItem -Path $objRoot -Recurse -Filter "libcompiler_rt.a" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    return $null
}

function Resolve-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint] $listener.LocalEndpoint).Port
    } finally {
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

function Remove-PathWithRetry {
    param([string] $Path)
    if (-not (Test-Path $Path)) { return }
    for ($attempt = 0; $attempt -lt 5; $attempt += 1) {
        try {
            Remove-Item -Force -ErrorAction Stop $Path
            return
        } catch {
            if ($attempt -ge 4) { throw }
            Start-Sleep -Milliseconds 100
        }
    }
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$zig = Resolve-ZigExecutable
$qemu = Resolve-QemuExecutable
$gdb = Resolve-GdbExecutable
$nm = Resolve-NmExecutable
$clang = Resolve-ClangExecutable
$lld = Resolve-LldExecutable
$compilerRt = Resolve-CompilerRtArchive
$zigGlobalCacheDir = Resolve-ZigGlobalCacheDir
$zigLocalCacheDir = if ($env:ZIG_LOCAL_CACHE_DIR -and $env:ZIG_LOCAL_CACHE_DIR.Trim().Length -gt 0) { $env:ZIG_LOCAL_CACHE_DIR } else { Join-Path $repo ".zig-cache" }

if ($null -eq $qemu -or $null -eq $gdb) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=$([bool]($null -ne $qemu))"
    Write-Output "BAREMETAL_GDB_AVAILABLE=$([bool]($null -ne $gdb))"
    Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE=skipped"
    return
}
if ($null -eq $clang -or $null -eq $lld -or $null -eq $compilerRt) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_BINARY=$nm"
    Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=False"
    if ($null -eq $clang) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=clang" }
    if ($null -eq $lld) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=lld" }
    if ($null -eq $compilerRt) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=libcompiler_rt.a" }
    Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE=skipped"
    return
}

if ($GdbPort -le 0) { $GdbPort = Resolve-FreeTcpPort }

$optionsPath = Join-Path $releaseDir "qemu-vga-console-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-vga-console-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-vga-console-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-vga-console-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-vga-console-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-vga-console-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-vga-console-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-vga-console-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-vga-console-probe-$runStamp.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
@"
pub const qemu_smoke: bool = false;
pub const console_probe_banner: bool = true;
"@ | Set-Content -Path $optionsPath -Encoding Ascii
    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-vga-console-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for VGA console probe runtime failed with exit code $LASTEXITCODE" }
    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for VGA console probe PVH shim failed with exit code $LASTEXITCODE" }
    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for VGA console probe PVH artifact failed with exit code $LASTEXITCODE" }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) {
    throw "Failed to resolve symbol table from $artifact using $nm"
}

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$consoleStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.vga_text_console\.state$' -SymbolName "baremetal.vga_text_console.state"
$artifactForGdb = $artifact.Replace('\', '/')

Remove-PathWithRetry $gdbStdout
Remove-PathWithRetry $gdbStderr
Remove-PathWithRetry $qemuStdout
Remove-PathWithRetry $qemuStderr

$gdbTemplate = @'
set pagination off
set confirm off
set remotecache off
set $stage = 0
file __ARTIFACT__
handle SIGQUIT nostop noprint pass
target remote :__GDBPORT__
break *0x__START__
commands
  silent
  printf "HIT_START=1\n"
  continue
end
break *0x__SPINPAUSE__
commands
  silent
  if $stage == 0
    set $stage = 1
    printf "CONSOLE_STATE_ADDR=%u\n", __CONSOLE_STATE_ADDR__
    printf "CONSOLE_MAGIC=%u\n", *(unsigned int*)(__CONSOLE_STATE_ADDR__ + __MAGIC_OFFSET__)
    printf "CONSOLE_API_VERSION=%u\n", *(unsigned short*)(__CONSOLE_STATE_ADDR__ + __API_VERSION_OFFSET__)
    printf "CONSOLE_COLS=%u\n", *(unsigned short*)(__CONSOLE_STATE_ADDR__ + __COLS_OFFSET__)
    printf "CONSOLE_ROWS=%u\n", *(unsigned short*)(__CONSOLE_STATE_ADDR__ + __ROWS_OFFSET__)
    printf "CONSOLE_CURSOR_ROW=%u\n", *(unsigned short*)(__CONSOLE_STATE_ADDR__ + __CURSOR_ROW_OFFSET__)
    printf "CONSOLE_CURSOR_COL=%u\n", *(unsigned short*)(__CONSOLE_STATE_ADDR__ + __CURSOR_COL_OFFSET__)
    printf "CONSOLE_BACKEND=%u\n", *(unsigned char*)(__CONSOLE_STATE_ADDR__ + __BACKEND_OFFSET__)
    printf "CONSOLE_WRITE_COUNT=%u\n", *(unsigned int*)(__CONSOLE_STATE_ADDR__ + __WRITE_COUNT_OFFSET__)
    printf "CONSOLE_SCROLL_COUNT=%u\n", *(unsigned int*)(__CONSOLE_STATE_ADDR__ + __SCROLL_COUNT_OFFSET__)
    printf "CONSOLE_CLEAR_COUNT=%u\n", *(unsigned int*)(__CONSOLE_STATE_ADDR__ + __CLEAR_COUNT_OFFSET__)
    printf "CONSOLE_CELL0=%u\n", *(unsigned short*)(__VGA_BUFFER_ADDR__)
    printf "CONSOLE_CELL1=%u\n", *(unsigned short*)(__VGA_BUFFER_ADDR__ + 2)
    printf "CONSOLE_VGA_CELL0=%u\n", *(unsigned short*)(__VGA_BUFFER_ADDR__)
    printf "CONSOLE_VGA_CELL1=%u\n", *(unsigned short*)(__VGA_BUFFER_ADDR__ + 2)
    quit
  end
  continue
end
continue
'@

$gdbScriptContent = $gdbTemplate `
    -replace '__ARTIFACT__', $artifactForGdb `
    -replace '__GDBPORT__', $GdbPort `
    -replace '__START__', $startAddress `
    -replace '__SPINPAUSE__', $spinPauseAddress `
    -replace '__CONSOLE_STATE_ADDR__', ('0x' + $consoleStateAddress) `
    -replace '__VGA_BUFFER_ADDR__', $vgaBufferAddr `
    -replace '__MAGIC_OFFSET__', $consoleMagicOffset `
    -replace '__API_VERSION_OFFSET__', $consoleApiVersionOffset `
    -replace '__COLS_OFFSET__', $consoleColsOffset `
    -replace '__ROWS_OFFSET__', $consoleRowsOffset `
    -replace '__CURSOR_ROW_OFFSET__', $consoleCursorRowOffset `
    -replace '__CURSOR_COL_OFFSET__', $consoleCursorColOffset `
    -replace '__BACKEND_OFFSET__', $consoleBackendOffset `
    -replace '__WRITE_COUNT_OFFSET__', $consoleWriteCountOffset `
    -replace '__SCROLL_COUNT_OFFSET__', $consoleScrollCountOffset `
    -replace '__CLEAR_COUNT_OFFSET__', $consoleClearCountOffset
$gdbScriptContent | Set-Content -Path $gdbScript -Encoding Ascii

$qemuProcess = $null
$gdbTimedOut = $false
try {
    $qemuArgs = @(
        "-M", "q35,accel=tcg"
        "-kernel", $artifact
        "-display", "none"
        "-serial", "stdio"
        "-monitor", "none"
        "-no-reboot"
        "-no-shutdown"
        "-S"
        "-gdb", "tcp::$GdbPort"
    )
    $qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -WindowStyle Hidden
    Start-Sleep -Milliseconds 500

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("-q", "-x", $gdbScript) -PassThru -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr -WindowStyle Hidden
    if (-not $gdbProcess.WaitForExit($TimeoutSeconds * 1000)) {
        $gdbTimedOut = $true
        try { $gdbProcess.Kill() } catch {}
    }

    if ($gdbTimedOut) { throw "gdb timed out after $TimeoutSeconds seconds" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode) { 0 } else { $gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        $stderrTail = if (Test-Path $gdbStderr) { (Get-Content $gdbStderr -Tail 80) -join "`n" } else { "" }
        throw "gdb exited with code $gdbExitCode`n$stderrTail"
    }
} finally {
    if ($qemuProcess -and -not $qemuProcess.HasExited) {
        try { $qemuProcess.Kill() } catch {}
        try { $qemuProcess.WaitForExit(2000) | Out-Null } catch {}
    }
}

$out = Get-Content -Path $gdbStdout -Raw
$hitStart = Extract-IntValue -Text $out -Name 'HIT_START'
$magic = Extract-IntValue -Text $out -Name 'CONSOLE_MAGIC'
$version = Extract-IntValue -Text $out -Name 'CONSOLE_API_VERSION'
$cols = Extract-IntValue -Text $out -Name 'CONSOLE_COLS'
$rows = Extract-IntValue -Text $out -Name 'CONSOLE_ROWS'
$cursorRow = Extract-IntValue -Text $out -Name 'CONSOLE_CURSOR_ROW'
$cursorCol = Extract-IntValue -Text $out -Name 'CONSOLE_CURSOR_COL'
$backend = Extract-IntValue -Text $out -Name 'CONSOLE_BACKEND'
$writeCount = Extract-IntValue -Text $out -Name 'CONSOLE_WRITE_COUNT'
$scrollCount = Extract-IntValue -Text $out -Name 'CONSOLE_SCROLL_COUNT'
$clearCount = Extract-IntValue -Text $out -Name 'CONSOLE_CLEAR_COUNT'
$cell0 = Extract-IntValue -Text $out -Name 'CONSOLE_CELL0'
$cell1 = Extract-IntValue -Text $out -Name 'CONSOLE_CELL1'
$vgaCell0 = Extract-IntValue -Text $out -Name 'CONSOLE_VGA_CELL0'
$vgaCell1 = Extract-IntValue -Text $out -Name 'CONSOLE_VGA_CELL1'

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_CLANG=$clang"
Write-Output "BAREMETAL_QEMU_PVH_LLD=$lld"
Write-Output "BAREMETAL_QEMU_PVH_COMPILER_RT=$compilerRt"
Write-Output "BAREMETAL_QEMU_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_START_ADDR=0x$startAddress"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_SPINPAUSE_ADDR=0x$spinPauseAddress"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_STATE_ADDR=0x$consoleStateAddress"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_MAGIC=$magic"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_API_VERSION=$version"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_COLS=$cols"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_ROWS=$rows"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_CURSOR_ROW=$cursorRow"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_CURSOR_COL=$cursorCol"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_BACKEND=$backend"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_WRITE_COUNT=$writeCount"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_SCROLL_COUNT=$scrollCount"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_CLEAR_COUNT=$clearCount"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_CELL0=$cell0"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_CELL1=$cell1"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_VGA_CELL0=$vgaCell0"
Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE_VGA_CELL1=$vgaCell1"

$pass = (
    $hitStart -eq 1 -and
    $magic -eq $consoleMagic -and
    $version -eq $apiVersion -and
    $cols -eq $expectedCols -and
    $rows -eq $expectedRows -and
    $cursorRow -eq 0 -and
    $cursorCol -eq 2 -and
    $backend -eq $consoleBackendVgaText -and
    $writeCount -eq 2 -and
    $scrollCount -eq 0 -and
    $clearCount -eq 1 -and
    $vgaCell0 -eq $expectedCellO -and
    $vgaCell1 -eq $expectedCellK
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_VGA_CONSOLE_PROBE=fail"
if (Test-Path $gdbStdout) { Get-Content -Path $gdbStdout -Tail 120 }
if (Test-Path $gdbStderr) { Get-Content -Path $gdbStderr -Tail 120 }
exit 1
