param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 30,
    [int] $DiskSizeMiB = 8
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$releaseDir = Join-Path $repo "release"
$expectedProbeCode = 0x40
$expectedExitCode = ($expectedProbeCode * 2) + 1
$partitionStartLba = 2048
$partitionSectorCount = 8192
$rawProbeLba = 48
$rawProbeSeed = 0x71
$filesystemSuperblockLba = 130
$toolLayoutMagic = 0x4f43544c
$filesystemMagic = 0x4f434653
$blockSize = 512
$gptHeaderLba = 1
$gptEntryLba = 2
$protectivePartitionType = 0xEE

function Resolve-ZigExecutable {
    $defaultWindowsZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
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

    throw "Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure `zig` is on PATH."
}

function Resolve-QemuExecutable {
    $candidates = @(
        "qemu-system-x86_64",
        "qemu-system-x86_64.exe",
        "C:\Program Files\qemu\qemu-system-x86_64.exe"
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
        "clang",
        "clang.exe",
        "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\clang.exe"
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
        "lld",
        "lld.exe",
        "C:\Users\Ady\Documents\starpro\tooling\emsdk\upstream\bin\lld.exe"
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
        $candidates += (Join-Path $env:LOCALAPPDATA "zig")
    }
    if ($env:XDG_CACHE_HOME -and $env:XDG_CACHE_HOME.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:XDG_CACHE_HOME "zig")
    }
    if ($env:HOME -and $env:HOME.Trim().Length -gt 0) {
        $candidates += (Join-Path $env:HOME ".cache/zig")
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }

    return (Join-Path $repo ".zig-global-cache")
}

function Resolve-CompilerRtArchive {
    $cacheRoot = Resolve-ZigGlobalCacheDir
    $objRoot = Join-Path $cacheRoot "o"
    if (-not (Test-Path $objRoot)) {
        return $null
    }

    $candidate = Get-ChildItem -Path $objRoot -Recurse -Filter "libcompiler_rt.a" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $candidate) {
        return $candidate.FullName
    }

    return $null
}

function New-RawDiskImage {
    param(
        [string] $Path,
        [int] $SizeMiB
    )

    if (Test-Path $Path) {
        Remove-Item -Force $Path
    }
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
    try {
        $stream.SetLength([int64]$SizeMiB * 1MB)
    } finally {
        $stream.Dispose()
    }
}

function Read-ImageByte {
    param(
        [byte[]] $Bytes,
        [uint32] $Lba,
        [uint32] $Offset
    )

    $index = ([int]$Lba * $blockSize) + [int]$Offset
    return [int]$Bytes[$index]
}

function Read-ImageU32LE {
    param(
        [byte[]] $Bytes,
        [uint32] $Lba
    )

    $index = [int]$Lba * $blockSize
    return [System.BitConverter]::ToUInt32($Bytes, $index)
}

function Write-ImageU32LE {
    param(
        [byte[]] $Bytes,
        [int] $Index,
        [uint32] $Value
    )

    $Bytes[$Index + 0] = [byte]($Value -band 0xFF)
    $Bytes[$Index + 1] = [byte](($Value -shr 8) -band 0xFF)
    $Bytes[$Index + 2] = [byte](($Value -shr 16) -band 0xFF)
    $Bytes[$Index + 3] = [byte](($Value -shr 24) -band 0xFF)
}

function Write-ImageU64LE {
    param(
        [byte[]] $Bytes,
        [int] $Index,
        [uint64] $Value
    )

    for ($i = 0; $i -lt 8; $i += 1) {
        $Bytes[$Index + $i] = [byte](($Value -shr (8 * $i)) -band 0xFF)
    }
}

function Initialize-GptPartitionedImage {
    param(
        [string] $Path,
        [int] $SizeMiB,
        [uint32] $PartitionStartLba,
        [uint32] $PartitionSectorCount
    )

    New-RawDiskImage -Path $Path -SizeMiB $SizeMiB
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $totalSectors = [uint32]($bytes.Length / $blockSize)
    if ($totalSectors -le $PartitionStartLba) {
        throw "Disk image is too small for ATA partition start LBA $PartitionStartLba."
    }

    if (($PartitionStartLba + $PartitionSectorCount) -gt $totalSectors) {
        throw "Disk image is too small for GPT partition span $PartitionStartLba+$PartitionSectorCount."
    }
    $entryOffset = 446
    $bytes[$entryOffset + 4] = $protectivePartitionType
    Write-ImageU32LE -Bytes $bytes -Index ($entryOffset + 8) -Value 1
    Write-ImageU32LE -Bytes $bytes -Index ($entryOffset + 12) -Value ($totalSectors - 1)
    $bytes[510] = 0x55
    $bytes[511] = 0xAA

    $gptHeaderOffset = $gptHeaderLba * $blockSize
    [System.Text.Encoding]::ASCII.GetBytes("EFI PART").CopyTo($bytes, $gptHeaderOffset)
    Write-ImageU32LE -Bytes $bytes -Index ($gptHeaderOffset + 8) -Value 0x00010000
    Write-ImageU32LE -Bytes $bytes -Index ($gptHeaderOffset + 12) -Value 92
    Write-ImageU64LE -Bytes $bytes -Index ($gptHeaderOffset + 24) -Value 1
    Write-ImageU64LE -Bytes $bytes -Index ($gptHeaderOffset + 32) -Value ($totalSectors - 1)
    Write-ImageU64LE -Bytes $bytes -Index ($gptHeaderOffset + 40) -Value 34
    Write-ImageU64LE -Bytes $bytes -Index ($gptHeaderOffset + 48) -Value ($totalSectors - 34)
    Write-ImageU64LE -Bytes $bytes -Index ($gptHeaderOffset + 72) -Value $gptEntryLba
    Write-ImageU32LE -Bytes $bytes -Index ($gptHeaderOffset + 80) -Value 4
    Write-ImageU32LE -Bytes $bytes -Index ($gptHeaderOffset + 84) -Value 128

    $gptEntryOffset = $gptEntryLba * $blockSize
    [byte[]]$typeGuid = 0xAF,0x3D,0xC6,0x0F,0x83,0x84,0x72,0x47,0x8E,0x79,0x3D,0x69,0xD8,0x47,0x7D,0xE4
    [byte[]]$uniqueGuid = 0x10,0x32,0x54,0x76,0x98,0xBA,0xDC,0xFE,0x01,0x23,0x45,0x67,0x89,0xAB,0xCD,0xEF
    $typeGuid.CopyTo($bytes, $gptEntryOffset)
    $uniqueGuid.CopyTo($bytes, $gptEntryOffset + 16)
    Write-ImageU64LE -Bytes $bytes -Index ($gptEntryOffset + 32) -Value $PartitionStartLba
    Write-ImageU64LE -Bytes $bytes -Index ($gptEntryOffset + 40) -Value ($PartitionStartLba + $PartitionSectorCount - 1)

    [System.IO.File]::WriteAllBytes($Path, $bytes)
    return $PartitionSectorCount
}

Set-Location $repo
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null

$zig = Resolve-ZigExecutable
$qemu = Resolve-QemuExecutable
$clang = Resolve-ClangExecutable
$lld = Resolve-LldExecutable
$compilerRt = Resolve-CompilerRtArchive
$zigGlobalCacheDir = Resolve-ZigGlobalCacheDir
$zigLocalCacheDir = if ($env:ZIG_LOCAL_CACHE_DIR -and $env:ZIG_LOCAL_CACHE_DIR.Trim().Length -gt 0) { $env:ZIG_LOCAL_CACHE_DIR } else { Join-Path $repo ".zig-cache" }

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_ATA_GPT_INSTALLER_PROBE=skipped"
    return
}

if ($null -eq $clang -or $null -eq $lld -or $null -eq $compilerRt) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
    Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
    Write-Output "BAREMETAL_QEMU_PVH_TOOLCHAIN_AVAILABLE=False"
    if ($null -eq $clang) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=clang" }
    if ($null -eq $lld) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=lld" }
    if ($null -eq $compilerRt) { Write-Output "BAREMETAL_QEMU_PVH_MISSING=libcompiler_rt.a" }
    Write-Output "BAREMETAL_QEMU_ATA_GPT_INSTALLER_PROBE=skipped"
    return
}

$optionsPath = Join-Path $releaseDir "qemu-ata-gpt-installer-probe-options.zig"
$mainObj = Join-Path $releaseDir "openclaw-zig-baremetal-main-ata-gpt-installer-probe.o"
$bootObj = Join-Path $releaseDir "openclaw-zig-pvh-boot-ata-gpt-installer-probe.o"
$artifact = Join-Path $releaseDir "openclaw-zig-baremetal-pvh-ata-gpt-installer-probe.elf"
$diskImage = Join-Path $releaseDir "qemu-ata-gpt-installer-probe.img"
$bootSource = Join-Path $repo "scripts\baremetal\pvh_boot.S"
$linkerScript = Join-Path $repo "scripts\baremetal\pvh_lld.ld"
$stdoutPath = Join-Path $releaseDir "qemu-ata-gpt-installer-probe.stdout.log"
$stderrPath = Join-Path $releaseDir "qemu-ata-gpt-installer-probe.stderr.log"

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
pub const tool_exec_probe: bool = false;
pub const rtl8139_gateway_probe: bool = false;
pub const ata_gpt_installer_probe: bool = true;
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
        --name "openclaw-zig-baremetal-main-ata-gpt-installer-probe" `
        "-femit-bin=$mainObj"
    if ($LASTEXITCODE -ne 0) {
        throw "zig build-obj for ATA GPT installer probe failed with exit code $LASTEXITCODE"
    }

    & $clang -c -target x86_64-unknown-elf $bootSource -o $bootObj
    if ($LASTEXITCODE -ne 0) {
        throw "clang assemble for ATA GPT installer PVH shim failed with exit code $LASTEXITCODE"
    }

    & $lld -flavor gnu -m elf_x86_64 -o $artifact -T $linkerScript $mainObj $bootObj $compilerRt
    if ($LASTEXITCODE -ne 0) {
        throw "lld link for ATA GPT installer PVH artifact failed with exit code $LASTEXITCODE"
    }
}

if (-not (Test-Path $artifact)) {
    throw "ATA GPT installer probe artifact is missing: $artifact"
}

$partitionSectorCount = Initialize-GptPartitionedImage -Path $diskImage -SizeMiB $DiskSizeMiB -PartitionStartLba $partitionStartLba -PartitionSectorCount $partitionSectorCount
if (Test-Path $stdoutPath) { Remove-Item -Force $stdoutPath }
if (Test-Path $stderrPath) { Remove-Item -Force $stderrPath }

$qemuArgs = @(
    "-kernel", $artifact,
    "-drive", "file=$diskImage,if=ide,format=raw,index=0,media=disk",
    "-nographic",
    "-no-reboot",
    "-no-shutdown",
    "-serial", "none",
    "-monitor", "none",
    "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04"
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
    throw "QEMU ATA GPT installer probe timed out after $TimeoutSeconds seconds."
}

$proc.WaitForExit()
$stdout = $stdoutTask.GetAwaiter().GetResult()
$stderr = $stderrTask.GetAwaiter().GetResult()
Set-Content -Path $stdoutPath -Value $stdout -Encoding Ascii
Set-Content -Path $stderrPath -Value $stderr -Encoding Ascii
$exitCode = $proc.ExitCode
if ($exitCode -ne $expectedExitCode) {
    $probeCode = [int](($exitCode - 1) / 2)
    throw ("QEMU ATA GPT installer probe failed with exit code {0} (probe code 0x{1:X2})." -f $exitCode, $probeCode)
}

$imageBytes = [System.IO.File]::ReadAllBytes($diskImage)
$rawProbePhysicalLba = $partitionStartLba + $rawProbeLba
$filesystemSuperblockPhysicalLba = $partitionStartLba + $filesystemSuperblockLba
$rawByte0 = Read-ImageByte -Bytes $imageBytes -Lba $rawProbePhysicalLba -Offset 0
$rawByte1 = Read-ImageByte -Bytes $imageBytes -Lba $rawProbePhysicalLba -Offset 1
$toolMagic = Read-ImageU32LE -Bytes $imageBytes -Lba $partitionStartLba
$fsMagic = Read-ImageU32LE -Bytes $imageBytes -Lba $filesystemSuperblockPhysicalLba
$mbrType = Read-ImageByte -Bytes $imageBytes -Lba 0 -Offset 450
$gptSignature = [System.Text.Encoding]::ASCII.GetString($imageBytes, $gptHeaderLba * $blockSize, 8)
$gptEntryStartLba = [System.BitConverter]::ToUInt64($imageBytes, ($gptEntryLba * $blockSize) + 32)

if ($rawByte0 -ne $rawProbeSeed -or $rawByte1 -ne ($rawProbeSeed + 1)) {
    throw "Host-side ATA raw readback did not match the expected pattern."
}
if ($toolMagic -ne $toolLayoutMagic) {
    throw ("Tool-layout superblock magic mismatch. Expected 0x{0:X8}, got 0x{1:X8}." -f $toolLayoutMagic, $toolMagic)
}
if ($fsMagic -ne $filesystemMagic) {
    throw ("Filesystem superblock magic mismatch. Expected 0x{0:X8}, got 0x{1:X8}." -f $filesystemMagic, $fsMagic)
}
if ($mbrType -ne $protectivePartitionType) {
    throw ("Protective MBR partition type mismatch. Expected 0x{0:X2}, got 0x{1:X2}." -f $protectivePartitionType, $mbrType)
}
if ($gptSignature -ne "EFI PART") {
    throw "GPT header signature mismatch."
}
if ($gptEntryStartLba -ne $partitionStartLba) {
    throw "GPT partition start LBA mismatch."
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_QEMU_ATA_GPT_INSTALLER_PROBE=pass"
Write-Output "BAREMETAL_QEMU_ATA_GPT_INSTALLER_IMAGE=$diskImage"
Write-Output "BAREMETAL_ATA_GPT_PARTITION_START_LBA=$partitionStartLba"
Write-Output "BAREMETAL_ATA_GPT_PARTITION_SECTOR_COUNT=$partitionSectorCount"
Write-Output "BAREMETAL_ATA_GPT_RAW_LBA48_BYTE0=$rawByte0"
Write-Output "BAREMETAL_ATA_GPT_RAW_LBA48_BYTE1=$rawByte1"
Write-Output ("BAREMETAL_ATA_TOOL_LAYOUT_MAGIC=0x{0:X8}" -f $toolMagic)
Write-Output ("BAREMETAL_ATA_FILESYSTEM_MAGIC=0x{0:X8}" -f $fsMagic)
Write-Output ("BAREMETAL_ATA_GPT_HEADER_SIGNATURE={0}" -f $gptSignature)
