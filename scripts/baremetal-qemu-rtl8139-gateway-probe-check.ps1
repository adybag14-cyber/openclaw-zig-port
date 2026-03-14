param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$releaseDir = Join-Path $repo 'release'
$expectedProbeCode = 0x3E
$expectedExitCode = ($expectedProbeCode * 2) + 1

function Resolve-ZigExecutable {
    $defaultWindowsZig = 'C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe'
    if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) {
        if (-not (Test-Path $env:OPENCLAW_ZIG_BIN)) {
            throw "OPENCLAW_ZIG_BIN is set but not found: $($env:OPENCLAW_ZIG_BIN)"
        }
        return $env:OPENCLAW_ZIG_BIN
    }

    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($null -ne $zigCmd -and $zigCmd.Path) {
        return $zigCmd.Path
    }

    if (Test-Path $defaultWindowsZig) {
        return $defaultWindowsZig
    }

    throw 'Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure `zig` is on PATH.'
}

function Resolve-QemuExecutable {
    $candidates = @(
        'qemu-system-x86_64',
        'qemu-system-x86_64.exe',
        'C:\Program Files\qemu\qemu-system-x86_64.exe'
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

function Resolve-ClangExecutable {
    $candidates = @(
        'clang',
        'clang.exe',
        'C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\clang.exe'
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

function Resolve-LldExecutable {
    $candidates = @(
        'lld',
        'lld.exe',
        'C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\lld.exe'
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

function Resolve-ZigGlobalCacheDir {
    $candidates = @()
    if ($env:ZIG_GLOBAL_CACHE_DIR -and $env:ZIG_GLOBAL_CACHE_DIR.Trim().Length -gt 0) {
        $candidates += $env:ZIG_GLOBAL_CACHE_DIR
    }
    if ($env:LOCALAPPDATA -and $env:LOCALAPPDATA.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'zig')
    }
    if ($env:XDG_CACHE_HOME -and $env:XDG_CACHE_HOME.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:XDG_CACHE_HOME 'zig')
    }
    if ($env:HOME -and $env:HOME.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:HOME '.cache/zig')
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return (Join-Path $repo '.zig-global-cache')
}

function Resolve-CompilerRtArchive {
    $cacheRoot = Resolve-ZigGlobalCacheDir
    $objRoot = Join-Path $cacheRoot 'o'
    if (-not (Test-Path $objRoot)) {
        return $null
    }

    $candidate = Get-ChildItem -Path $objRoot -Recurse -Filter 'libcompiler_rt.a' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $candidate) {
        return $candidate.FullName
    }

    return $null
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$zig = Resolve-ZigExecutable
$qemu = Resolve-QemuExecutable
$clang = Resolve-ClangExecutable
$lld = Resolve-LldExecutable
$compilerRt = Resolve-CompilerRtArchive
$zigGlobalCacheDir = Resolve-ZigGlobalCacheDir
$zigLocalCacheDir = if ($env:ZIG_LOCAL_CACHE_DIR -and $env:ZIG_LOCAL_CACHE_DIR.Trim().Length -gt 0) { $env:ZIG_LOCAL_CACHE_DIR } else { Join-Path $repo '.zig-cache' }

if ($null -eq $qemu) {
    Write-Output 'BAREMETAL_QEMU_AVAILABLE=False'
    Write-Output 'BAREMETAL_QEMU_RTL8139_GATEWAY_PROBE=skipped'
    return
}

if ($null -eq $clang -or $null -eq $lld -or $null -eq $compilerRt) {
    Write-Output 'BAREMETAL_QEMU_AVAILABLE=True'
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output 'BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=False'
    if ($null -eq $clang) { Write-Output 'BAREMETAL_QEMU_PVH_MISSING=clang' }
    if ($null -eq $lld) { Write-Output 'BAREMETAL_QEMU_PVH_MISSING=lld' }
    if ($null -eq $compilerRt) { Write-Output 'BAREMETAL_QEMU_PVH_MISSING=libcompiler_rt.a' }
    Write-Output 'BAREMETAL_QEMU_RTL8139_GATEWAY_PROBE=skipped'
    return
}

$optionsPath = Join-Path $releaseDir 'qemu-rtl8139-gateway-probe-options.zig'
$mainObj = Join-Path $releaseDir 'openclaw-zig-baremetal-main-rtl8139-gateway-probe.o'
$bootObj = Join-Path $releaseDir 'openclaw-zig-pvh-boot-rtl8139-gateway-probe.o'
$artifact = Join-Path $releaseDir 'openclaw-zig-baremetal-pvh-rtl8139-gateway-probe.elf'
$bootSource = Join-Path $repo 'scripts\baremetal\pvh_boot.S'
$linkerScript = Join-Path $repo 'scripts\baremetal\pvh_lld.ld'
$stdoutPath = Join-Path $releaseDir 'qemu-rtl8139-gateway-probe.stdout.log'
$stderrPath = Join-Path $releaseDir 'qemu-rtl8139-gateway-probe.stderr.log'

if (-not $SkipBuild) {
    New-Item -ItemType Directory -Force -Path $zigGlobalCacheDir | Out-Null
    New-Item -ItemType Directory -Force -Path $zigLocalCacheDir | Out-Null
    @"
pub const qemu_smoke: bool = false;
pub const console_probe_banner: bool = false;
pub const framebuffer_probe_banner: bool = false;
pub const ata_storage_probe: bool = false;
pub const rtl8139_probe: bool = false;
pub const rtl8139_arp_probe: bool = false;
pub const rtl8139_ipv4_probe: bool = false;
pub const rtl8139_udp_probe: bool = false;
pub const rtl8139_tcp_probe: bool = false;
pub const rtl8139_dhcp_probe: bool = false;
pub const rtl8139_dns_probe: bool = false;
pub const rtl8139_gateway_probe: bool = true;
pub const tool_exec_probe: bool = false;
"@ | Set-Content -Path $optionsPath -Encoding Ascii

    & $zig build-obj `
        -fno-strip `
        -fsingle-threaded `
        -ODebug `
        -target x86_64-freestanding-none `
        -mcpu baseline `
        --dep build_options `
        "-Mroot=$repo\src\baremetal_main.zig" `
        "-Mbuild_options=$optionsPath" `
        --cache-dir "$zigLocalCacheDir" `
        --global-cache-dir "$zigGlobalCacheDir" `
        --name 'openclaw-zig-baremetal-main-rtl8139-gateway-probe' `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for RTL8139 gateway probe failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for RTL8139 PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for RTL8139 PVH artifact failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path $artifact)) {
    throw "RTL8139 gateway probe artifact is missing: $artifact"
}

if (Test-Path $stdoutPath) { Remove-Item -Force $stdoutPath }
if (Test-Path $stderrPath) { Remove-Item -Force $stderrPath }

$qemuArgs = @(
    '-kernel', $artifact,
    '-nographic',
    '-no-reboot',
    '-no-shutdown',
    '-serial', 'none',
    '-monitor', 'none',
    '-netdev', 'user,id=n0,restrict=on',
    '-device', 'rtl8139,netdev=n0',
    '-device', 'isa-debug-exit,iobase=0xf4,iosize=0x04'
)

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $qemu
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.Arguments = (($qemuArgs | ForEach-Object {
    if ("$_" -match '[\s"]') {
        '"{0}"' -f (($_ -replace '"', '\"'))
    } else {
        "$_"
    }
}) -join ' ')

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
[void]$proc.Start()
$stdoutTask = $proc.StandardOutput.ReadToEndAsync()
$stderrTask = $proc.StandardError.ReadToEndAsync()

if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    try { $proc.Kill($true) } catch {}
    throw "QEMU RTL8139 gateway probe timed out after $TimeoutSeconds seconds."
}

$proc.WaitForExit()
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
Set-Content -Path $stdoutPath -Value $stdout -Encoding Ascii
Set-Content -Path $stderrPath -Value $stderr -Encoding Ascii
$exitCode = $proc.ExitCode
if ($exitCode -ne $expectedExitCode) {
    $probeCode = [int](($exitCode - 1) / 2)
    throw ("QEMU RTL8139 gateway probe failed with exit code {0} (probe code 0x{1:X2})." -f $exitCode, $probeCode)
}

Write-Output 'BAREMETAL_QEMU_AVAILABLE=True'
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output 'BAREMETAL_QEMU_RTL8139_GATEWAY_PROBE=pass'
Write-Output ("BAREMETAL_QEMU_RTL8139_GATEWAY_PROBE_CODE=0x{0:X2}" -f $expectedProbeCode)
Write-Output "BAREMETAL_QEMU_RTL8139_GATEWAY_STDOUT=$stdoutPath"
Write-Output "BAREMETAL_QEMU_RTL8139_GATEWAY_STDERR=$stderrPath"





