param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-allocator-syscall-reset-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match '(?m)^BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_DIRTY_ALLOCATOR_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator-syscall-reset probe failed with exit code $probeExitCode"
}

$dirtyAllocPtr = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_PTR'
$dirtyAllocFreePages = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_FREE_PAGES'
$dirtyAllocCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_COUNT'
$dirtyAllocOps = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_OPS'
$dirtyAllocBytes = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_BYTES'
$dirtyAllocPeak = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_PEAK'
$dirtyAllocRecord0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_RECORD0_STATE'
$dirtyAllocRecord0PageLen = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_DIRTY_ALLOC_RECORD0_PAGE_LEN'

if ($null -in @($dirtyAllocPtr, $dirtyAllocFreePages, $dirtyAllocCount, $dirtyAllocOps, $dirtyAllocBytes, $dirtyAllocPeak, $dirtyAllocRecord0State, $dirtyAllocRecord0PageLen)) {
    throw 'Missing expected dirty allocator fields in allocator-syscall-reset probe output.'
}
if ($dirtyAllocPtr -eq 0) { throw "Expected DIRTY_ALLOC_PTR to be nonzero. got $dirtyAllocPtr" }
if ($dirtyAllocFreePages -ne 254) { throw "Expected DIRTY_ALLOC_FREE_PAGES=254. got $dirtyAllocFreePages" }
if ($dirtyAllocCount -ne 1) { throw "Expected DIRTY_ALLOC_COUNT=1. got $dirtyAllocCount" }
if ($dirtyAllocOps -ne 1) { throw "Expected DIRTY_ALLOC_OPS=1. got $dirtyAllocOps" }
if ($dirtyAllocBytes -ne 8192) { throw "Expected DIRTY_ALLOC_BYTES=8192. got $dirtyAllocBytes" }
if ($dirtyAllocPeak -ne 8192) { throw "Expected DIRTY_ALLOC_PEAK=8192. got $dirtyAllocPeak" }
if ($dirtyAllocRecord0State -ne 1) { throw "Expected DIRTY_ALLOC_RECORD0_STATE=1. got $dirtyAllocRecord0State" }
if ($dirtyAllocRecord0PageLen -ne 2) { throw "Expected DIRTY_ALLOC_RECORD0_PAGE_LEN=2. got $dirtyAllocRecord0PageLen" }

Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_DIRTY_ALLOCATOR_PROBE=pass'
Write-Output "DIRTY_ALLOC_PTR=$dirtyAllocPtr"
Write-Output "DIRTY_ALLOC_FREE_PAGES=$dirtyAllocFreePages"
Write-Output "DIRTY_ALLOC_COUNT=$dirtyAllocCount"
Write-Output "DIRTY_ALLOC_OPS=$dirtyAllocOps"
Write-Output "DIRTY_ALLOC_BYTES=$dirtyAllocBytes"
Write-Output "DIRTY_ALLOC_PEAK=$dirtyAllocPeak"
Write-Output "DIRTY_ALLOC_RECORD0_STATE=$dirtyAllocRecord0State"
Write-Output "DIRTY_ALLOC_RECORD0_PAGE_LEN=$dirtyAllocRecord0PageLen"
