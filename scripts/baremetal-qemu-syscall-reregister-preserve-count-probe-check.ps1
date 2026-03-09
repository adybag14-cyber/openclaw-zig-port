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
    Write-Output 'BAREMETAL_QEMU_SYSCALL_REREGISTER_PRESERVE_COUNT_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_SYSCALL_REREGISTER_PRESERVE_COUNT_PROBE_SOURCE=baremetal-qemu-syscall-control-probe-check.ps1'
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

$updatedToken = Extract-IntValue -Text $outputText -Name 'UPDATED_TOKEN'
$entryCount = Extract-IntValue -Text $outputText -Name 'ENTRY_COUNT'
$entry0State = Extract-IntValue -Text $outputText -Name 'ENTRY0_STATE'
$entry0InvokeCount = Extract-IntValue -Text $outputText -Name 'ENTRY0_INVOKE_COUNT'

if ($updatedToken -ne 51966) { throw "Expected UPDATED_TOKEN=51966 after re-register. got $updatedToken" }
if ($entryCount -ne 0) { throw "Expected final ENTRY_COUNT=0 after cleanup. got $entryCount" }
if ($entry0State -ne 0) { throw "Expected ENTRY0_STATE=0 after cleanup. got $entry0State" }
if ($entry0InvokeCount -ne 0) { throw "Expected ENTRY0_INVOKE_COUNT=0 after cleanup. got $entry0InvokeCount" }

Write-Output 'BAREMETAL_QEMU_SYSCALL_REREGISTER_PRESERVE_COUNT_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_SYSCALL_REREGISTER_PRESERVE_COUNT_PROBE_SOURCE=baremetal-qemu-syscall-control-probe-check.ps1'
Write-Output "UPDATED_TOKEN=$updatedToken"
Write-Output "ENTRY_COUNT=$entryCount"
Write-Output "ENTRY0_STATE=$entry0State"
Write-Output "ENTRY0_INVOKE_COUNT=$entry0InvokeCount"
