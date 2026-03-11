param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-manual-wait-interrupt-probe-check.ps1'

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_PRESERVE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_PRESERVE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait-interrupt probe failed with exit code $probeExitCode"
}

$waitState = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_STATE_BEFORE_INTERRUPT'
$waitTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_TASK_COUNT_BEFORE_INTERRUPT'
$waitKind = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_KIND_BEFORE_INTERRUPT'
if ($null -in @($waitState, $waitTaskCount, $waitKind)) { throw 'Missing wait-preserve fields in manual-wait-interrupt probe output.' }
if ($waitState -ne 6) { throw "Expected WAIT_STATE_BEFORE_INTERRUPT=6, got $waitState" }
if ($waitTaskCount -ne 0) { throw "Expected WAIT_TASK_COUNT_BEFORE_INTERRUPT=0, got $waitTaskCount" }
if ($waitKind -ne 1) { throw "Expected WAIT_KIND_BEFORE_INTERRUPT=1, got $waitKind" }
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_PRESERVE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_WAIT_PRESERVE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output 'WAIT_STATE_BEFORE_INTERRUPT=6'
Write-Output 'WAIT_TASK_COUNT_BEFORE_INTERRUPT=0'
Write-Output 'WAIT_KIND_BEFORE_INTERRUPT=1'
