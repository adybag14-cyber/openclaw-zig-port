param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 1348
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-interrupt-mask-exception-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_HISTORY_CAPTURE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_HISTORY_CAPTURE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-exception-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Interrupt mask exception prerequisite probe failed with exit code $exitCode"
}

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$required = @(
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE'; Expected = 'pass'; Type = 'string' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY_LEN'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY_LEN'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_SEQ'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_VECTOR'; Expected = 13; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_IS_EXCEPTION'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_CODE'; Expected = 51966; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_INTERRUPT_COUNT'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_INTERRUPT_HISTORY0_EXCEPTION_COUNT'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_SEQ'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_VECTOR'; Expected = 13; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_CODE'; Expected = 51966; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_INTERRUPT_COUNT'; Expected = 1; Type = 'int' },
    @{ Name = 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_PROBE_EXCEPTION_HISTORY0_EXCEPTION_COUNT'; Expected = 1; Type = 'int' }
)

foreach ($item in $required) {
    if ($item.Type -eq 'string') {
        $match = [regex]::Match($outputText, '(?m)^' + [regex]::Escape($item.Name) + '=(.+)$')
        if (-not $match.Success) { throw "Missing output value for $($item.Name)" }
        if ($match.Groups[1].Value.Trim() -ne $item.Expected) { throw "Unexpected $($item.Name): got $($match.Groups[1].Value.Trim()) expected $($item.Expected)" }
    } else {
        $value = Extract-IntValue -Text $outputText -Name $item.Name
        if ($null -eq $value) { throw "Missing output value for $($item.Name)" }
        if ($value -ne $item.Expected) { throw "Unexpected $($item.Name): got $value expected $($item.Expected)" }
    }
}

Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_HISTORY_CAPTURE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_EXCEPTION_HISTORY_CAPTURE_PROBE_SOURCE=baremetal-qemu-interrupt-mask-exception-probe-check.ps1'
Write-Output 'INTERRUPT_HISTORY_LEN=1'
Write-Output 'EXCEPTION_HISTORY_LEN=1'
Write-Output 'INTERRUPT_HISTORY0_SEQ=1'
Write-Output 'INTERRUPT_HISTORY0_VECTOR=13'
Write-Output 'INTERRUPT_HISTORY0_IS_EXCEPTION=1'
Write-Output 'INTERRUPT_HISTORY0_CODE=51966'
Write-Output 'INTERRUPT_HISTORY0_INTERRUPT_COUNT=1'
Write-Output 'INTERRUPT_HISTORY0_EXCEPTION_COUNT=1'
Write-Output 'EXCEPTION_HISTORY0_SEQ=1'
Write-Output 'EXCEPTION_HISTORY0_VECTOR=13'
Write-Output 'EXCEPTION_HISTORY0_CODE=51966'
Write-Output 'EXCEPTION_HISTORY0_INTERRUPT_COUNT=1'
Write-Output 'EXCEPTION_HISTORY0_EXCEPTION_COUNT=1'
