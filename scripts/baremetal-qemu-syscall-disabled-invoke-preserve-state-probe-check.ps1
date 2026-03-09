param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 1287
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-syscall-control-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_SYSCALL_CONTROL_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SYSCALL_DISABLED_INVOKE_PRESERVE_STATE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_SYSCALL_DISABLED_INVOKE_PRESERVE_STATE_PROBE_SOURCE=baremetal-qemu-syscall-control-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Syscall control prerequisite probe failed with exit code $exitCode"
}

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$disabledResult = Extract-IntValue -Text $outputText -Name 'DISABLED_RESULT'
$enabled = Extract-IntValue -Text $outputText -Name 'ENABLED'
$dispatchCount = Extract-IntValue -Text $outputText -Name 'DISPATCH_COUNT'
$stateLastResult = Extract-IntValue -Text $outputText -Name 'STATE_LAST_RESULT'

if ($disabledResult -ne -38) { throw "Expected DISABLED_RESULT=-38. got $disabledResult" }
if ($enabled -ne 1) { throw "Expected final ENABLED=1 after re-enable. got $enabled" }
if ($dispatchCount -ne 1) { throw "Expected final DISPATCH_COUNT=1 after the later successful invoke only. got $dispatchCount" }
if ($stateLastResult -ne 55489) { throw "Expected STATE_LAST_RESULT=55489 from the later successful invoke. got $stateLastResult" }

Write-Output 'BAREMETAL_QEMU_SYSCALL_DISABLED_INVOKE_PRESERVE_STATE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_SYSCALL_DISABLED_INVOKE_PRESERVE_STATE_PROBE_SOURCE=baremetal-qemu-syscall-control-probe-check.ps1'
Write-Output "DISABLED_RESULT=$disabledResult"
Write-Output "ENABLED=$enabled"
Write-Output "DISPATCH_COUNT=$dispatchCount"
Write-Output "STATE_LAST_RESULT=$stateLastResult"
