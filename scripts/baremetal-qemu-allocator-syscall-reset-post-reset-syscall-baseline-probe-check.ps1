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
    Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_POST_RESET_SYSCALL_BASELINE_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying allocator-syscall-reset probe failed with exit code $probeExitCode"
}

$postSyscallEnabled = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_ENABLED'
$postSyscallEntryCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_ENTRY_COUNT'
$postSyscallLastId = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_LAST_ID'
$postSyscallDispatchCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_DISPATCH_COUNT'
$postSyscallLastInvokeTick = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_LAST_INVOKE_TICK'
$postSyscallLastResult = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_LAST_RESULT'
$postSyscallEntry0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_PROBE_POST_SYSCALL_ENTRY0_STATE'

if ($null -in @($postSyscallEnabled, $postSyscallEntryCount, $postSyscallLastId, $postSyscallDispatchCount, $postSyscallLastInvokeTick, $postSyscallLastResult, $postSyscallEntry0State)) {
    throw 'Missing expected post-reset syscall fields in allocator-syscall-reset probe output.'
}
if ($postSyscallEnabled -ne 1) { throw "Expected POST_SYSCALL_ENABLED=1. got $postSyscallEnabled" }
if ($postSyscallEntryCount -ne 0) { throw "Expected POST_SYSCALL_ENTRY_COUNT=0. got $postSyscallEntryCount" }
if ($postSyscallLastId -ne 0) { throw "Expected POST_SYSCALL_LAST_ID=0. got $postSyscallLastId" }
if ($postSyscallDispatchCount -ne 0) { throw "Expected POST_SYSCALL_DISPATCH_COUNT=0. got $postSyscallDispatchCount" }
if ($postSyscallLastInvokeTick -ne 0) { throw "Expected POST_SYSCALL_LAST_INVOKE_TICK=0. got $postSyscallLastInvokeTick" }
if ($postSyscallLastResult -ne 0) { throw "Expected POST_SYSCALL_LAST_RESULT=0. got $postSyscallLastResult" }
if ($postSyscallEntry0State -ne 0) { throw "Expected POST_SYSCALL_ENTRY0_STATE=0. got $postSyscallEntry0State" }

Write-Output 'BAREMETAL_QEMU_ALLOCATOR_SYSCALL_RESET_POST_RESET_SYSCALL_BASELINE_PROBE=pass'
Write-Output "POST_SYSCALL_ENABLED=$postSyscallEnabled"
Write-Output "POST_SYSCALL_ENTRY_COUNT=$postSyscallEntryCount"
Write-Output "POST_SYSCALL_LAST_ID=$postSyscallLastId"
Write-Output "POST_SYSCALL_DISPATCH_COUNT=$postSyscallDispatchCount"
Write-Output "POST_SYSCALL_LAST_INVOKE_TICK=$postSyscallLastInvokeTick"
Write-Output "POST_SYSCALL_LAST_RESULT=$postSyscallLastResult"
Write-Output "POST_SYSCALL_ENTRY0_STATE=$postSyscallEntry0State"
