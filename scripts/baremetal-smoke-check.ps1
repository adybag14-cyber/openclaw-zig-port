param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

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

function Read-UInt16LE {
    param([byte[]] $Bytes, [int] $Offset)
    return [System.BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-UInt32LE {
    param([byte[]] $Bytes, [int] $Offset)
    return [System.BitConverter]::ToUInt32($Bytes, $Offset)
}

function Read-UInt64LE {
    param([byte[]] $Bytes, [int] $Offset)
    return [System.BitConverter]::ToUInt64($Bytes, $Offset)
}

function Read-CString {
    param(
        [byte[]] $Table,
        [int] $Offset
    )
    if ($Offset -lt 0 -or $Offset -ge $Table.Length) {
        return ""
    }
    $end = $Offset
    while ($end -lt $Table.Length -and $Table[$end] -ne 0) {
        $end++
    }
    if ($end -le $Offset) {
        return ""
    }
    return [System.Text.Encoding]::ASCII.GetString($Table, $Offset, $end - $Offset)
}

function Find-BytePatternIndex {
    param(
        [byte[]] $Bytes,
        [byte[]] $Pattern
    )
    if ($Pattern.Length -eq 0 -or $Bytes.Length -lt $Pattern.Length) {
        return -1
    }
    for ($i = 0; $i -le ($Bytes.Length - $Pattern.Length); $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Pattern[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $i
        }
    }
    return -1
}

function Find-BytePatternIndexInRange {
    param(
        [byte[]] $Bytes,
        [byte[]] $Pattern,
        [int] $StartOffset,
        [int] $EndOffsetExclusive
    )
    if ($Pattern.Length -eq 0 -or $Bytes.Length -lt $Pattern.Length) {
        return -1
    }
    if ($StartOffset -lt 0) {
        $StartOffset = 0
    }
    if ($EndOffsetExclusive -gt $Bytes.Length) {
        $EndOffsetExclusive = $Bytes.Length
    }
    $maxStart = $EndOffsetExclusive - $Pattern.Length
    if ($maxStart -lt $StartOffset) {
        return -1
    }
    for ($i = $StartOffset; $i -le $maxStart; $i++) {
        $matched = $true
        for ($j = 0; $j -lt $Pattern.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Pattern[$j]) {
                $matched = $false
                break
            }
        }
        if ($matched) {
            return $i
        }
    }
    return -1
}

Set-Location $repo
$zig = Resolve-ZigExecutable

if (-not $SkipBuild) {
    & $zig build baremetal --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "zig build baremetal failed with exit code $LASTEXITCODE"
    }
}

$candidates = @(
    (Join-Path $repo "zig-out\openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out/openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out\bin\openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out/bin/openclaw-zig-baremetal.elf")
)

$artifact = $null
foreach ($candidate in $candidates) {
    if (Test-Path $candidate) {
        $artifact = (Resolve-Path $candidate).Path
        break
    }
}

if ($null -eq $artifact) {
    throw "bare-metal artifact not found in expected zig-out paths."
}

$info = Get-Item $artifact
if ($info.Length -le 0) {
    throw "bare-metal artifact is empty: $artifact"
}

$bytes = [System.IO.File]::ReadAllBytes($artifact)
if ($bytes.Length -lt 64) {
    throw "artifact too small for ELF64 header: $artifact"
}
if ($bytes[0] -ne 0x7F -or $bytes[1] -ne 0x45 -or $bytes[2] -ne 0x4C -or $bytes[3] -ne 0x46) {
    throw "artifact is not an ELF binary: $artifact"
}
if ($bytes[4] -ne 2) {
    throw "artifact is not ELF64 (EI_CLASS != 2)"
}
if ($bytes[5] -ne 1) {
    throw "artifact is not little-endian ELF (EI_DATA != 1)"
}

# Multiboot2 magic in little-endian
$multiboot2Magic = [byte[]] @(0xD6, 0x50, 0x52, 0xE8)
$multibootOffset = Find-BytePatternIndex -Bytes $bytes -Pattern $multiboot2Magic
if ($multibootOffset -lt 0) {
    throw "multiboot2 header magic not found in bare-metal artifact"
}
if ($multibootOffset -ge 32768) {
    throw "multiboot2 header was not found in first 32768 bytes (offset=$multibootOffset)"
}
if (($multibootOffset % 8) -ne 0) {
    throw "multiboot2 header is not 8-byte aligned (offset=$multibootOffset)"
}

$multibootMagicValue = Read-UInt32LE -Bytes $bytes -Offset $multibootOffset
$multibootMagicHex = "{0:X8}" -f ([uint32]$multibootMagicValue)
$multibootArchitecture = Read-UInt32LE -Bytes $bytes -Offset ($multibootOffset + 4)
$multibootHeaderLength = Read-UInt32LE -Bytes $bytes -Offset ($multibootOffset + 8)
$multibootChecksum = Read-UInt32LE -Bytes $bytes -Offset ($multibootOffset + 12)
$multibootEndTagType = Read-UInt16LE -Bytes $bytes -Offset ($multibootOffset + 16)
$multibootEndTagFlags = Read-UInt16LE -Bytes $bytes -Offset ($multibootOffset + 18)
$multibootEndTagSize = Read-UInt32LE -Bytes $bytes -Offset ($multibootOffset + 20)

if ($multibootMagicHex -ne "E85250D6") {
    throw "invalid multiboot2 magic value: 0x$multibootMagicHex"
}
if ($multibootArchitecture -ne 0) {
    throw "unsupported multiboot2 architecture value: $multibootArchitecture (expected 0)"
}
if ($multibootHeaderLength -ne 24) {
    throw "unexpected multiboot2 header length: $multibootHeaderLength (expected 24)"
}
if (($multibootOffset + $multibootHeaderLength) -gt $bytes.Length) {
    throw "multiboot2 header exceeds file bounds"
}
$multibootChecksumRaw = [uint64]$multibootMagicValue + [uint64]$multibootArchitecture + [uint64]$multibootHeaderLength + [uint64]$multibootChecksum
$multibootChecksumSum = $multibootChecksumRaw % 4294967296
if ($multibootChecksumSum -ne 0) {
    throw ("invalid multiboot2 checksum (sum mod 2^32 = 0x{0:X8})" -f $multibootChecksumSum)
}
if ($multibootEndTagType -ne 0 -or $multibootEndTagFlags -ne 0 -or $multibootEndTagSize -ne 8) {
    throw "invalid multiboot2 end tag values (type=$multibootEndTagType flags=$multibootEndTagFlags size=$multibootEndTagSize)"
}

$sectionHeaderOffset = [int](Read-UInt64LE -Bytes $bytes -Offset 0x28)
$sectionHeaderEntrySize = [int](Read-UInt16LE -Bytes $bytes -Offset 0x3A)
$sectionHeaderCount = [int](Read-UInt16LE -Bytes $bytes -Offset 0x3C)
$sectionHeaderStrIndex = [int](Read-UInt16LE -Bytes $bytes -Offset 0x3E)

if ($sectionHeaderOffset -le 0 -or $sectionHeaderEntrySize -le 0 -or $sectionHeaderCount -le 0) {
    throw "invalid ELF section header metadata"
}

$maxSectionHeaderBytes = $sectionHeaderOffset + ($sectionHeaderEntrySize * $sectionHeaderCount)
if ($maxSectionHeaderBytes -gt $bytes.Length) {
    throw "ELF section headers exceed file bounds"
}
if ($sectionHeaderStrIndex -ge $sectionHeaderCount) {
    throw "invalid section name string table index"
}

$rawSections = @()
for ($index = 0; $index -lt $sectionHeaderCount; $index++) {
    $base = $sectionHeaderOffset + ($index * $sectionHeaderEntrySize)
    $rawSections += [pscustomobject]@{
        Index = $index
        NameOffset = [int](Read-UInt32LE -Bytes $bytes -Offset $base)
        Type = [int](Read-UInt32LE -Bytes $bytes -Offset ($base + 4))
        Offset = [int](Read-UInt64LE -Bytes $bytes -Offset ($base + 24))
        Size = [int](Read-UInt64LE -Bytes $bytes -Offset ($base + 32))
        Link = [int](Read-UInt32LE -Bytes $bytes -Offset ($base + 40))
        EntrySize = [int](Read-UInt64LE -Bytes $bytes -Offset ($base + 56))
    }
}

$shStr = $rawSections[$sectionHeaderStrIndex]
$shStrEnd = $shStr.Offset + $shStr.Size
if ($shStr.Offset -lt 0 -or $shStr.Size -lt 0 -or $shStrEnd -gt $bytes.Length) {
    throw "invalid ELF section-name string table bounds"
}
$sectionNameTable = New-Object byte[] $shStr.Size
[Array]::Copy($bytes, $shStr.Offset, $sectionNameTable, 0, $shStr.Size)

$sections = @()
foreach ($section in $rawSections) {
    $sections += [pscustomobject]@{
        Index = $section.Index
        Name = Read-CString -Table $sectionNameTable -Offset $section.NameOffset
        Type = $section.Type
        Offset = $section.Offset
        Size = $section.Size
        Link = $section.Link
        EntrySize = $section.EntrySize
    }
}

$multibootSection = $sections | Where-Object { $_.Name -eq ".multiboot" } | Select-Object -First 1
if ($null -eq $multibootSection) {
    throw "ELF section '.multiboot' not found"
}
if (($multibootSection.Offset % 8) -ne 0) {
    throw ".multiboot section offset is not 8-byte aligned ($($multibootSection.Offset))"
}
$multibootSectionEnd = $multibootSection.Offset + $multibootSection.Size
$multibootSectionHeaderOffset = Find-BytePatternIndexInRange -Bytes $bytes -Pattern $multiboot2Magic -StartOffset $multibootSection.Offset -EndOffsetExclusive $multibootSectionEnd
if ($multibootSectionHeaderOffset -lt 0) {
    throw "multiboot2 magic not found in .multiboot section bytes"
}
if (($multibootSectionHeaderOffset % 8) -ne 0) {
    throw "multiboot2 header inside .multiboot is not 8-byte aligned (offset=$multibootSectionHeaderOffset)"
}
$multibootSectionHeaderLength = Read-UInt32LE -Bytes $bytes -Offset ($multibootSectionHeaderOffset + 8)
if (($multibootSectionHeaderOffset + $multibootSectionHeaderLength) -gt $multibootSectionEnd) {
    throw "multiboot2 header bytes are not fully contained in .multiboot section"
}

$symtab = $sections | Where-Object { $_.Name -eq ".symtab" } | Select-Object -First 1
if ($null -eq $symtab) {
    throw "ELF symbol table '.symtab' not found"
}
if ($symtab.EntrySize -le 0) {
    throw "ELF symbol table has invalid entry size"
}
if ($symtab.Link -lt 0 -or $symtab.Link -ge $sections.Count) {
    throw "ELF symbol table has invalid linked string table index"
}

$symtabEnd = $symtab.Offset + $symtab.Size
if ($symtab.Offset -lt 0 -or $symtab.Size -lt 0 -or $symtabEnd -gt $bytes.Length) {
    throw "ELF symbol table bounds are invalid"
}

$strtab = $sections[$symtab.Link]
$strtabEnd = $strtab.Offset + $strtab.Size
if ($strtab.Offset -lt 0 -or $strtab.Size -lt 0 -or $strtabEnd -gt $bytes.Length) {
    throw "ELF symbol string table bounds are invalid"
}

$symbolStringTable = New-Object byte[] $strtab.Size
[Array]::Copy($bytes, $strtab.Offset, $symbolStringTable, 0, $strtab.Size)

$symbolCount = [int]($symtab.Size / $symtab.EntrySize)
$symbols = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
for ($i = 0; $i -lt $symbolCount; $i++) {
    $entryBase = $symtab.Offset + ($i * $symtab.EntrySize)
    $nameOffset = [int](Read-UInt32LE -Bytes $bytes -Offset $entryBase)
    if ($nameOffset -le 0) {
        continue
    }
    $name = Read-CString -Table $symbolStringTable -Offset $nameOffset
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        [void]$symbols.Add($name)
    }
}

$requiredSymbols = @(
    "_start",
    "oc_tick",
    "oc_tick_n",
    "oc_status_ptr",
    "oc_boot_diag_ptr",
    "oc_boot_diag_capture_stack",
    "oc_command_ptr",
    "oc_kernel_info_ptr",
    "oc_submit_command",
    "oc_gdtr_ptr",
    "oc_idtr_ptr",
    "oc_gdt_ptr",
    "oc_idt_ptr",
    "oc_descriptor_tables_ready",
    "oc_descriptor_tables_loaded",
    "oc_descriptor_load_attempt_count",
    "oc_descriptor_load_success_count",
    "oc_try_load_descriptor_tables",
    "oc_last_interrupt_vector",
    "oc_interrupt_count",
    "oc_interrupt_vector_counts_ptr",
    "oc_interrupt_vector_count",
    "oc_last_exception_vector",
    "oc_exception_count",
    "oc_exception_vector_counts_ptr",
    "oc_exception_vector_count",
    "oc_last_exception_code",
    "oc_exception_history_capacity",
    "oc_exception_history_len",
    "oc_exception_history_head_index",
    "oc_exception_history_overflow_count",
    "oc_exception_history_ptr",
    "oc_exception_history_event",
    "oc_exception_history_clear",
    "oc_interrupt_history_capacity",
    "oc_interrupt_history_len",
    "oc_interrupt_history_head_index",
    "oc_interrupt_history_overflow_count",
    "oc_interrupt_history_ptr",
    "oc_interrupt_history_event",
    "oc_interrupt_history_clear",
    "oc_descriptor_init_count",
    "oc_interrupt_state_ptr",
    "oc_reset_interrupt_counters",
    "oc_reset_exception_counters",
    "oc_reset_vector_counters",
    "oc_trigger_interrupt",
    "oc_trigger_exception",
    "oc_exception_stub",
    "oc_interrupt_stub",
    "kernel_info",
    "multiboot2_header"
)
foreach ($required in $requiredSymbols) {
    if (-not $symbols.Contains($required)) {
        throw "required symbol not found in ELF symtab: $required"
    }
}

Write-Output "BAREMETAL_BUILD_HTTP=200"
Write-Output "BAREMETAL_ARTIFACT=$artifact"
Write-Output "BAREMETAL_SIZE_BYTES=$($info.Length)"
Write-Output "BAREMETAL_ELF_MAGIC_PRESENT=True"
Write-Output "BAREMETAL_MULTIBOOT2_MAGIC_PRESENT=True"
Write-Output "BAREMETAL_MULTIBOOT2_OFFSET=$multibootOffset"
Write-Output "BAREMETAL_MULTIBOOT2_ARCH=$multibootArchitecture"
Write-Output "BAREMETAL_MULTIBOOT2_LENGTH=$multibootHeaderLength"
Write-Output "BAREMETAL_MULTIBOOT2_CHECKSUM=0x$("{0:X8}" -f $multibootChecksum)"
Write-Output "BAREMETAL_MULTIBOOT2_END_TAG_TYPE=$multibootEndTagType"
Write-Output "BAREMETAL_MULTIBOOT2_END_TAG_SIZE=$multibootEndTagSize"
Write-Output "BAREMETAL_MULTIBOOT_SECTION_PRESENT=True"
Write-Output "BAREMETAL_SYMTAB_PRESENT=True"
Write-Output "BAREMETAL_REQUIRED_SYMBOLS_PRESENT=True"
Write-Output "BAREMETAL_SYMBOL_COUNT=$symbolCount"
