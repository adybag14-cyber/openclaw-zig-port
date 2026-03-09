param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-scheduler-disable-enable-probe-check.ps1"
$schedulerEnableOpcode = 24

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
if ($probeText -match 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_PROBE=skipped') {
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_RESUME_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying scheduler-disable-enable probe failed with exit code $probeExitCode"
}

$ack = Extract-IntValue -Text $probeText -Name 'ACK'
$lastOpcode = Extract-IntValue -Text $probeText -Name 'LAST_OPCODE'
$lastResult = Extract-IntValue -Text $probeText -Name 'LAST_RESULT'
$enabled = Extract-IntValue -Text $probeText -Name 'ENABLED'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'DISPATCH_COUNT'

if ($null -in @($ack, $lastOpcode, $lastResult, $enabled, $dispatchCount)) {
    throw 'Missing expected resume fields in scheduler-disable-enable probe output.'
}
if ($ack -ne 5) { throw "Expected ACK=5. got $ack" }
if ($lastOpcode -ne $schedulerEnableOpcode) { throw "Expected LAST_OPCODE=24. got $lastOpcode" }
if ($lastResult -ne 0) { throw "Expected LAST_RESULT=0. got $lastResult" }
if ($enabled -ne 1) { throw "Expected ENABLED=1 after resume. got $enabled" }
if ($dispatchCount -ne 2) { throw "Expected DISPATCH_COUNT=2 after resume. got $dispatchCount" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_DISABLE_ENABLE_RESUME_PROBE=pass'
Write-Output "ACK=$ack"
Write-Output "LAST_OPCODE=$lastOpcode"
Write-Output "LAST_RESULT=$lastResult"
Write-Output "ENABLED=$enabled"
Write-Output "DISPATCH_COUNT=$dispatchCount"