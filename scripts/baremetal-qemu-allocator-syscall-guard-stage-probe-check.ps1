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
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_GUARD_STAGE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator-syscall probe failed with exit code $probeExitCode"
}

$blockedResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_BLOCKED_COMMAND_RESULT'
$blockedInvokeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_BLOCKED_INVOKE_COUNT_SNAPSHOT'
$disabledResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_DISABLED_COMMAND_RESULT'
$reenabledResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_COMMAND_RESULT'
$reenabledDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_DISPATCH_COUNT_SNAPSHOT'
$reenabledInvokeCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_INVOKE_COUNT_SNAPSHOT'
$reenabledLastArg = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_LAST_ARG_SNAPSHOT'
$reenabledFlags = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_ENTRY_FLAGS_SNAPSHOT'
$reenabledLastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_PROBE_REENABLED_LAST_RESULT_SNAPSHOT'
if ($null -in @($blockedResult,$blockedInvokeCount,$disabledResult,$reenabledResult,$reenabledDispatchCount,$reenabledInvokeCount,$reenabledLastArg,$reenabledFlags,$reenabledLastResult)) { throw 'Missing guard stage fields.' }
if ($blockedResult -ne -17) { throw "Expected BLOCKED_COMMAND_RESULT=-17. got $blockedResult" }
if ($blockedInvokeCount -ne 1) { throw "Expected BLOCKED_INVOKE_COUNT_SNAPSHOT=1. got $blockedInvokeCount" }
if ($disabledResult -ne -38) { throw "Expected DISABLED_COMMAND_RESULT=-38. got $disabledResult" }
if ($reenabledResult -ne 0) { throw "Expected REENABLED_COMMAND_RESULT=0. got $reenabledResult" }
if ($reenabledDispatchCount -ne 2) { throw "Expected REENABLED_DISPATCH_COUNT_SNAPSHOT=2. got $reenabledDispatchCount" }
if ($reenabledInvokeCount -ne 2) { throw "Expected REENABLED_INVOKE_COUNT_SNAPSHOT=2. got $reenabledInvokeCount" }
if ($reenabledLastArg -ne 4660) { throw "Expected REENABLED_LAST_ARG_SNAPSHOT=4660. got $reenabledLastArg" }
if ($reenabledFlags -ne 0) { throw "Expected REENABLED_ENTRY_FLAGS_SNAPSHOT=0. got $reenabledFlags" }
if ($reenabledLastResult -ne 47206) { throw "Expected REENABLED_LAST_RESULT_SNAPSHOT=47206. got $reenabledLastResult" }
Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_GUARD_STAGE_PROBE=pass'
Write-Output "BLOCKED_COMMAND_RESULT=$blockedResult"
Write-Output "DISABLED_COMMAND_RESULT=$disabledResult"
Write-Output "REENABLED_COMMAND_RESULT=$reenabledResult"
Write-Output "REENABLED_DISPATCH_COUNT_SNAPSHOT=$reenabledDispatchCount"
