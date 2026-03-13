param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$runStamp = [DateTime]::UtcNow.ToString("yyyyMMddHHmmssfff")

$framebufferMagic = 0x4f434642
$apiVersion = 2
$consoleBackendFramebuffer = 2
$expectedWidth = 640
$expectedHeight = 400
$expectedCols = 80
$expectedRows = 25
$expectedPitch = 2560
$expectedFramebufferBytes = 1024000
$expectedBytesPerPixel = 4
$expectedCellWidth = 8
$expectedCellHeight = 16
$expectedFgColor = 0x00FFFFFF
$expectedBgColor = 0x00000000

$stateMagicOffset = 0
$stateApiVersionOffset = 4
$stateWidthOffset = 6
$stateHeightOffset = 8
$stateColsOffset = 10
$stateRowsOffset = 12
$statePitchOffset = 16
$stateFramebufferBytesOffset = 20
$stateFramebufferAddrOffset = 24
$stateBytesPerPixelOffset = 32
$stateBackendOffset = 33
$stateHardwareBackedOffset = 34
$stateWriteCountOffset = 36
$stateClearCountOffset = 40
$statePresentCountOffset = 44
$stateCellWidthOffset = 48
$stateCellHeightOffset = 49
$stateFgColorOffset = 52
$stateBgColorOffset = 56

$pixel0OffsetBytes = 0
$pixelOOffsetBytes = (((1 * $expectedWidth) + 3) * 4)
$pixelKOffsetBytes = (((1 * $expectedWidth) + 9) * 4)

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
    Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE=skipped"
    return
}
if ($null -eq $nm) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_GDB_BINARY=$gdb"
    Write-Output "BAREMETAL_NM_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE=skipped"
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
    Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE=skipped"
    return
}

if ($GdbPort -le 0) { $GdbPort = Resolve-FreeTcpPort }

$optionsPath = Join-Path $releaseDir "qemu-framebuffer-console-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-framebuffer-console-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-framebuffer-console-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-framebuffer-console-probe.elf"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$gdbScript = Join-Path $releaseDir "qemu-framebuffer-console-probe-$runStamp.gdb"
$gdbStdout = Join-Path $releaseDir "qemu-framebuffer-console-probe-$runStamp.gdb.stdout.log"
$gdbStderr = Join-Path $releaseDir "qemu-framebuffer-console-probe-$runStamp.gdb.stderr.log"
$qemuStdout = Join-Path $releaseDir "qemu-framebuffer-console-probe-$runStamp.qemu.stdout.log"
$qemuStderr = Join-Path $releaseDir "qemu-framebuffer-console-probe-$runStamp.qemu.stderr.log"

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
@"
pub const qemu_smoke: bool = false;
pub const console_probe_banner: bool = false;
pub const framebuffer_probe_banner: bool = true;
pub const ata_storage_probe: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii

    & $zig build-obj -fno-strip -fsingle-threaded -ODebug -target x86_64-freestanding-none -mcpu baseline --dep build_options "-Mroot=$repo\src\baremetal_main.zig" "-Mbuild_options=$optionsPath" --cache-dir "$zigLocalCacheDir" --global-cache-dir "$zigGlobalCacheDir" --name "openclaw-zig-baremetal-main-framebuffer-console-probe" "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) { throw "zig build-obj for framebuffer console probe runtime failed with exit code $LASTEXITCODE" }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) { throw "clang assemble for framebuffer console PVH shim failed with exit code $LASTEXITCODE" }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) { throw "lld link for framebuffer console PVH artifact failed with exit code $LASTEXITCODE" }
}

$symbolOutput = & $nm $artifact
if ($LASTEXITCODE -ne 0 -or $null -eq $symbolOutput -or $symbolOutput.Count -eq 0) {
    throw "Failed to resolve symbol table from $artifact using $nm"
}

$startAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[Tt]\s_start$' -SymbolName "_start"
$spinPauseAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[tT]\sbaremetal_main\.spinPause$' -SymbolName "baremetal_main.spinPause"
$framebufferStateAddress = Resolve-SymbolAddress -SymbolLines $symbolOutput -Pattern '\s[dDbB]\sbaremetal\.framebuffer_console\.state$' -SymbolName "baremetal.framebuffer_console.state"
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
    set $fb = *(unsigned long long*)(__FRAMEBUFFER_STATE_ADDR__ + __FRAMEBUFFER_ADDR_OFFSET__)
    printf "FRAMEBUFFER_STATE_ADDR=%llu\n", (unsigned long long)__FRAMEBUFFER_STATE_ADDR__
    printf "FRAMEBUFFER_MAGIC=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __MAGIC_OFFSET__)
    printf "FRAMEBUFFER_API_VERSION=%u\n", *(unsigned short*)(__FRAMEBUFFER_STATE_ADDR__ + __API_VERSION_OFFSET__)
    printf "FRAMEBUFFER_WIDTH=%u\n", *(unsigned short*)(__FRAMEBUFFER_STATE_ADDR__ + __WIDTH_OFFSET__)
    printf "FRAMEBUFFER_HEIGHT=%u\n", *(unsigned short*)(__FRAMEBUFFER_STATE_ADDR__ + __HEIGHT_OFFSET__)
    printf "FRAMEBUFFER_COLS=%u\n", *(unsigned short*)(__FRAMEBUFFER_STATE_ADDR__ + __COLS_OFFSET__)
    printf "FRAMEBUFFER_ROWS=%u\n", *(unsigned short*)(__FRAMEBUFFER_STATE_ADDR__ + __ROWS_OFFSET__)
    printf "FRAMEBUFFER_PITCH=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __PITCH_OFFSET__)
    printf "FRAMEBUFFER_BYTES=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __FRAMEBUFFER_BYTES_OFFSET__)
    printf "FRAMEBUFFER_ADDR=%llu\n", $fb
    printf "FRAMEBUFFER_BPP=%u\n", *(unsigned char*)(__FRAMEBUFFER_STATE_ADDR__ + __BYTES_PER_PIXEL_OFFSET__)
    printf "FRAMEBUFFER_BACKEND=%u\n", *(unsigned char*)(__FRAMEBUFFER_STATE_ADDR__ + __BACKEND_OFFSET__)
    printf "FRAMEBUFFER_HARDWARE_BACKED=%u\n", *(unsigned char*)(__FRAMEBUFFER_STATE_ADDR__ + __HARDWARE_BACKED_OFFSET__)
    printf "FRAMEBUFFER_WRITE_COUNT=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __WRITE_COUNT_OFFSET__)
    printf "FRAMEBUFFER_CLEAR_COUNT=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __CLEAR_COUNT_OFFSET__)
    printf "FRAMEBUFFER_PRESENT_COUNT=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __PRESENT_COUNT_OFFSET__)
    printf "FRAMEBUFFER_CELL_WIDTH=%u\n", *(unsigned char*)(__FRAMEBUFFER_STATE_ADDR__ + __CELL_WIDTH_OFFSET__)
    printf "FRAMEBUFFER_CELL_HEIGHT=%u\n", *(unsigned char*)(__FRAMEBUFFER_STATE_ADDR__ + __CELL_HEIGHT_OFFSET__)
    printf "FRAMEBUFFER_FG_COLOR=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __FG_COLOR_OFFSET__)
    printf "FRAMEBUFFER_BG_COLOR=%u\n", *(unsigned int*)(__FRAMEBUFFER_STATE_ADDR__ + __BG_COLOR_OFFSET__)
    printf "FRAMEBUFFER_PIXEL0=%u\n", *(unsigned int*)($fb + __PIXEL0_OFFSET__)
    printf "FRAMEBUFFER_PIXEL_O=%u\n", *(unsigned int*)($fb + __PIXEL_O_OFFSET__)
    printf "FRAMEBUFFER_PIXEL_K=%u\n", *(unsigned int*)($fb + __PIXEL_K_OFFSET__)
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
    -replace '__FRAMEBUFFER_STATE_ADDR__', ('0x' + $framebufferStateAddress) `
    -replace '__MAGIC_OFFSET__', $stateMagicOffset `
    -replace '__API_VERSION_OFFSET__', $stateApiVersionOffset `
    -replace '__WIDTH_OFFSET__', $stateWidthOffset `
    -replace '__HEIGHT_OFFSET__', $stateHeightOffset `
    -replace '__COLS_OFFSET__', $stateColsOffset `
    -replace '__ROWS_OFFSET__', $stateRowsOffset `
    -replace '__PITCH_OFFSET__', $statePitchOffset `
    -replace '__FRAMEBUFFER_BYTES_OFFSET__', $stateFramebufferBytesOffset `
    -replace '__FRAMEBUFFER_ADDR_OFFSET__', $stateFramebufferAddrOffset `
    -replace '__BYTES_PER_PIXEL_OFFSET__', $stateBytesPerPixelOffset `
    -replace '__BACKEND_OFFSET__', $stateBackendOffset `
    -replace '__HARDWARE_BACKED_OFFSET__', $stateHardwareBackedOffset `
    -replace '__WRITE_COUNT_OFFSET__', $stateWriteCountOffset `
    -replace '__CLEAR_COUNT_OFFSET__', $stateClearCountOffset `
    -replace '__PRESENT_COUNT_OFFSET__', $statePresentCountOffset `
    -replace '__CELL_WIDTH_OFFSET__', $stateCellWidthOffset `
    -replace '__CELL_HEIGHT_OFFSET__', $stateCellHeightOffset `
    -replace '__FG_COLOR_OFFSET__', $stateFgColorOffset `
    -replace '__BG_COLOR_OFFSET__', $stateBgColorOffset `
    -replace '__PIXEL0_OFFSET__', $pixel0OffsetBytes `
    -replace '__PIXEL_O_OFFSET__', $pixelOOffsetBytes `
    -replace '__PIXEL_K_OFFSET__', $pixelKOffsetBytes
$gdbScriptContent | Set-Content -Path $gdbScript -Encoding Ascii

$qemuProcess = $null
$gdbTimedOut = $false
try {
    $qemuArgs = @(
        "-M", "q35,accel=tcg"
        "-cpu", "qemu64"
        "-m", "128M"
        "-kernel", $artifact
        "-display", "none"
        "-serial", "none"
        "-monitor", "none"
        "-vga", "std"
        "-no-reboot"
        "-no-shutdown"
        "-S"
        "-gdb", "tcp::$GdbPort"
    )
    $qemuProcess = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -RedirectStandardOutput $qemuStdout -RedirectStandardError $qemuStderr -WindowStyle Hidden
    Start-Sleep -Milliseconds 600

    $gdbProcess = Start-Process -FilePath $gdb -ArgumentList @("-q", "-x", $gdbScript) -PassThru -RedirectStandardOutput $gdbStdout -RedirectStandardError $gdbStderr -WindowStyle Hidden
    if (-not $gdbProcess.WaitForExit($TimeoutSeconds * 1000)) {
        $gdbTimedOut = $true
        try { $gdbProcess.Kill() } catch {}
    }

    if ($gdbTimedOut) { throw "gdb timed out after $TimeoutSeconds seconds" }
    $gdbExitCode = if ($null -eq $gdbProcess.ExitCode) { 0 } else { $gdbProcess.ExitCode }
    if ($gdbExitCode -ne 0) {
        $stderrTail = if (Test-Path $gdbStderr) { (Get-Content $gdbStderr -Tail 120) -join "`n" } else { "" }
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
$magic = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_MAGIC'
$version = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_API_VERSION'
$width = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_WIDTH'
$height = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_HEIGHT'
$cols = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_COLS'
$rows = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_ROWS'
$pitch = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_PITCH'
$framebufferBytes = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_BYTES'
$framebufferAddr = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_ADDR'
$bytesPerPixel = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_BPP'
$backend = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_BACKEND'
$hardwareBacked = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_HARDWARE_BACKED'
$writeCount = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_WRITE_COUNT'
$clearCount = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_CLEAR_COUNT'
$presentCount = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_PRESENT_COUNT'
$cellWidth = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_CELL_WIDTH'
$cellHeight = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_CELL_HEIGHT'
$fgColor = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_FG_COLOR'
$bgColor = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_BG_COLOR'
$pixel0 = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_PIXEL0'
$pixelO = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_PIXEL_O'
$pixelK = Extract-IntValue -Text $out -Name 'FRAMEBUFFER_PIXEL_K'

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_GDB_BINARY=$gdb"
Write-Output "BAREMETAL_NM_BINARY=$nm"
Write-Output "BAREMETAL_QEMU_PVH_CLANG=$clang"
Write-Output "BAREMETAL_QEMU_PVH_LLD=$lld"
Write-Output "BAREMETAL_QEMU_PVH_COMPILER_RT=$compilerRt"
Write-Output "BAREMETAL_QEMU_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_HIT_START=$hitStart"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_MAGIC=$magic"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_API_VERSION=$version"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_WIDTH=$width"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_HEIGHT=$height"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_COLS=$cols"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_ROWS=$rows"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_PITCH=$pitch"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_FRAMEBUFFER_BYTES=$framebufferBytes"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_FRAMEBUFFER_ADDR=$framebufferAddr"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_BPP=$bytesPerPixel"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_BACKEND=$backend"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_HARDWARE_BACKED=$hardwareBacked"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_WRITE_COUNT=$writeCount"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_CLEAR_COUNT=$clearCount"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_PRESENT_COUNT=$presentCount"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_CELL_WIDTH=$cellWidth"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_CELL_HEIGHT=$cellHeight"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_FG_COLOR=$fgColor"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_BG_COLOR=$bgColor"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_PIXEL0=$pixel0"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_PIXEL_O=$pixelO"
Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE_PIXEL_K=$pixelK"

$pass = (
    $hitStart -eq 1 -and
    $magic -eq $framebufferMagic -and
    $version -eq $apiVersion -and
    $width -eq $expectedWidth -and
    $height -eq $expectedHeight -and
    $cols -eq $expectedCols -and
    $rows -eq $expectedRows -and
    $pitch -eq $expectedPitch -and
    $framebufferBytes -eq $expectedFramebufferBytes -and
    $framebufferAddr -gt 0 -and
    (($framebufferAddr % 4096) -eq 0) -and
    $bytesPerPixel -eq $expectedBytesPerPixel -and
    $backend -eq $consoleBackendFramebuffer -and
    $hardwareBacked -eq 1 -and
    $writeCount -eq 2 -and
    $clearCount -eq 0 -and
    $presentCount -eq 2 -and
    $cellWidth -eq $expectedCellWidth -and
    $cellHeight -eq $expectedCellHeight -and
    $fgColor -eq $expectedFgColor -and
    $bgColor -eq $expectedBgColor -and
    $pixel0 -eq $expectedBgColor -and
    $pixelO -eq $expectedFgColor -and
    $pixelK -eq $expectedFgColor
)

if ($pass) {
    Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE=pass"
    exit 0
}

Write-Output "BAREMETAL_QEMU_FRAMEBUFFER_CONSOLE_PROBE=fail"
if (Test-Path $gdbStdout) { Get-Content -Path $gdbStdout -Tail 160 }
if (Test-Path $gdbStderr) { Get-Content -Path $gdbStderr -Tail 160 }
if (Test-Path $qemuStdout) { Get-Content -Path $qemuStdout -Tail 80 }
if (Test-Path $qemuStderr) { Get-Content -Path $qemuStderr -Tail 80 }
exit 1
