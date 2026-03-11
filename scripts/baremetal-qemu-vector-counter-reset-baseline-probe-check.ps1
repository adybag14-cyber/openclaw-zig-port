param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-vector-counter-reset-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(.+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value.Trim()
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_PROBE=skipped') {
    Write-Output "BAREMETAL_QEMU_VECTOR_COUNTER_RESET_BASELINE_PROBE=skipped"
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying vector-counter-reset probe failed with exit code $probeExitCode"
}

$artifact = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_ARTIFACT'
$startAddr = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_START_ADDR'
$statusAddr = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_STATUS_ADDR'
$mailboxAddr = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_MAILBOX_ADDR'
$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_TICKS'

if ([string]::IsNullOrWhiteSpace($artifact) -or [string]::IsNullOrWhiteSpace($startAddr) -or [string]::IsNullOrWhiteSpace($statusAddr) -or [string]::IsNullOrWhiteSpace($mailboxAddr) -or [string]::IsNullOrWhiteSpace($ticks)) {
    throw 'Missing baseline vector-counter-reset receipt fields in probe output.'
}
if (-not ($startAddr -like '0x*') -or -not ($statusAddr -like '0x*') -or -not ($mailboxAddr -like '0x*')) {
    throw "Unexpected address encoding in vector-counter-reset baseline output. start=$startAddr status=$statusAddr mailbox=$mailboxAddr"
}
if ([int64]$ticks -lt 8) {
    throw "Expected TICKS>=8 in vector-counter-reset baseline output, got $ticks"
}

Write-Output 'BAREMETAL_QEMU_VECTOR_COUNTER_RESET_BASELINE_PROBE=pass'
Write-Output "ARTIFACT=$artifact"
Write-Output "START_ADDR=$startAddr"
Write-Output "STATUS_ADDR=$statusAddr"
Write-Output "MAILBOX_ADDR=$mailboxAddr"
Write-Output "TICKS=$ticks"
