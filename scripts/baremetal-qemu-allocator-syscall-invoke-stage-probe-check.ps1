param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-allocator-syscall-probe-check.ps1"

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
if ($probeText -match '(?m)^BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE=skipped\r?$') {
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_INVOKE_STAGE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator-syscall probe failed with exit code $probeExitCode"
}

$invokeResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_LAST_RESULT_SNAPSHOT'
$dispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_DISPATCH_COUNT_SNAPSHOT'
$invokeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_COUNT_SNAPSHOT'
$lastArg = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_INVOKE_LAST_ARG_SNAPSHOT'
if ($null -in @($invokeResult,$dispatchCount,$invokeCount,$lastArg)) { throw 'Missing invoke stage fields.' }
if ($invokeResult -ne 47206) { throw "Expected INVOKE_LAST_RESULT_SNAPSHOT=47206. got $invokeResult" }
if ($dispatchCount -ne 1) { throw "Expected INVOKE_DISPATCH_COUNT_SNAPSHOT=1. got $dispatchCount" }
if ($invokeCount -ne 1) { throw "Expected INVOKE_COUNT_SNAPSHOT=1. got $invokeCount" }
if ($lastArg -ne 4660) { throw "Expected INVOKE_LAST_ARG_SNAPSHOT=4660. got $lastArg" }
Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_INVOKE_STAGE_PROBE=pass'
Write-Output "INVOKE_LAST_RESULT_SNAPSHOT=$invokeResult"
Write-Output "INVOKE_DISPATCH_COUNT_SNAPSHOT=$dispatchCount"
Write-Output "INVOKE_COUNT_SNAPSHOT=$invokeCount"
Write-Output "INVOKE_LAST_ARG_SNAPSHOT=$lastArg"
