param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-round-robin-probe-check.ps1"

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FINAL_TASK_STATE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-round-robin probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_LAST_RESULT'
$ticks = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_TICKS'
$taskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_TASK_COUNT'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_DISPATCH_COUNT'
$policy = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_POLICY'

if ($null -in @($ack, $lastOpcode, $lastResult, $ticks, $taskCount, $dispatchCount, $policy)) {
    throw 'Missing expected final-state fields in scheduler-round-robin probe output.'
}
if ($ack -ne 6) { throw "Expected ACK=6. got $ack" }
if ($lastOpcode -ne 24) { throw "Expected LAST_OPCODE=24. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($ticks -lt 8) { throw "Expected TICKS >= 8. got $ticks" }
if ($taskCount -ne 2) { throw "Expected TASK_COUNT=2. got $taskCount" }
if ($dispatchCount -lt 3) { throw "Expected DISPATCH_COUNT >= 3. got $dispatchCount" }
if ($policy -ne 0) { throw "Expected POLICY=0. got $policy" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_ROUND_ROBIN_FINAL_TASK_STATE_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "TICKS=$ticks"
Write-Output "TASK_COUNT=$taskCount"
Write-Output "DISPATCH_COUNT=$dispatchCount"
Write-Output "POLICY=$policy"
