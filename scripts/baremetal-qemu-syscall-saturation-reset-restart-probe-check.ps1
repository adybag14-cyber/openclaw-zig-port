param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 45,
    [int] $GdbPort = 0
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-syscall-saturation-reset-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_SYSCALL_SATURATION_RESET_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_RESET_RESTART_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_RESET_RESTART_PROBE_SOURCE=baremetal-qemu-syscall-saturation-reset-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Syscall saturation-reset prerequisite probe failed with exit code $exitCode"
}

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$postResetEntryCount = Extract-IntValue -Text $outputText -Name 'POST_RESET_ENTRY_COUNT'
$postResetDispatchCount = Extract-IntValue -Text $outputText -Name 'POST_RESET_DISPATCH_COUNT'
$postResetFirstState = Extract-IntValue -Text $outputText -Name 'POST_RESET_FIRST_STATE'
$freshId = Extract-IntValue -Text $outputText -Name 'FRESH_ID'
$secondSlotState = Extract-IntValue -Text $outputText -Name 'SECOND_SLOT_STATE'
$freshInvokeCount = Extract-IntValue -Text $outputText -Name 'FRESH_INVOKE_COUNT'

if ($postResetEntryCount -ne 0) { throw "Expected POST_RESET_ENTRY_COUNT=0. got $postResetEntryCount" }
if ($postResetDispatchCount -ne 0) { throw "Expected POST_RESET_DISPATCH_COUNT=0. got $postResetDispatchCount" }
if ($postResetFirstState -ne 0) { throw "Expected POST_RESET_FIRST_STATE=0. got $postResetFirstState" }
if ($freshId -ne 777) { throw "Expected FRESH_ID=777 after reset restart. got $freshId" }
if ($secondSlotState -ne 0) { throw "Expected SECOND_SLOT_STATE=0 after fresh restart. got $secondSlotState" }
if ($freshInvokeCount -ne 1) { throw "Expected FRESH_INVOKE_COUNT=1 after fresh invoke. got $freshInvokeCount" }

Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_RESET_RESTART_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_SYSCALL_SATURATION_RESET_RESTART_PROBE_SOURCE=baremetal-qemu-syscall-saturation-reset-probe-check.ps1'
Write-Output "POST_RESET_ENTRY_COUNT=$postResetEntryCount"
Write-Output "POST_RESET_DISPATCH_COUNT=$postResetDispatchCount"
Write-Output "POST_RESET_FIRST_STATE=$postResetFirstState"
Write-Output "FRESH_ID=$freshId"
Write-Output "SECOND_SLOT_STATE=$secondSlotState"
Write-Output "FRESH_INVOKE_COUNT=$freshInvokeCount"
