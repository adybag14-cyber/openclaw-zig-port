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
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying manual-wait-interrupt probe failed with exit code $probeExitCode"
}

$taskId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TASK_ID'
$taskPriority = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TASK_PRIORITY'
$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_LAST_RESULT'
$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_TICKS'
if ($null -in @($taskId, $taskPriority, $ack, $lastOpcode, $lastResult, $ticks)) { throw 'Missing baseline fields in manual-wait-interrupt probe output.' }
if ($taskId -le 0) { throw "Expected TASK_ID > 0, got $taskId" }
if ($taskPriority -ne 0) { throw "Expected TASK_PRIORITY=0, got $taskPriority" }
if ($ack -ne 9) { throw "Expected ACK=9, got $ack" }
if ($lastOpcode -ne 45) { throw "Expected LAST_OPCODE=45, got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0, got $lastResult" }
if ($ticks -lt 9) { throw "Expected TICKS >= 9, got $ticks" }
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MANUAL_WAIT_INTERRUPT_BASELINE_PROBE_SOURCE=baremetal-qemu-manual-wait-interrupt-probe-check.ps1'
Write-Output "TASK_ID=$taskId"
Write-Output 'TASK_PRIORITY=0'
Write-Output 'ACK=9'
Write-Output 'LAST_OPCODE=45'
Write-Output 'LAST_RESULT=0'
Write-Output "TICKS=$ticks"
