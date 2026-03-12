param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$invoke = @{ TimeoutSeconds = $TimeoutSeconds }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$output = & $probe @invoke 2>&1
$exitCode = $LASTEXITCODE
$outputText = ($output | Out-String)
if ($outputText -match '(?m)^BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE=skipped\r?$') {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_COMMAND_PRESERVE_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_COMMAND_PRESERVE_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
    exit 0
}
if ($exitCode -ne 0) {
    if ($outputText) { Write-Output $outputText.TrimEnd() }
    throw "Health-history overflow/clear prerequisite probe failed with exit code $exitCode"
}

$commandPreserveLen = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_PRESERVE_LEN'
$commandTailOpcode = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_TAIL_OPCODE'
$commandTailResult = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_TAIL_RESULT'
$commandTailArg0 = Extract-IntValue -Text $outputText -Name 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_TAIL_ARG0'
if ($commandPreserveLen -ne 2 -or $commandTailOpcode -ne 20 -or $commandTailResult -ne 0 -or $commandTailArg0 -ne 0) {
    throw "Unexpected preserved command-history tail. commandPreserveLen=$commandPreserveLen commandTailOpcode=$commandTailOpcode commandTailResult=$commandTailResult commandTailArg0=$commandTailArg0"
}

Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_COMMAND_PRESERVE_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_COMMAND_PRESERVE_PROBE_SOURCE=baremetal-qemu-health-history-overflow-clear-probe-check.ps1'
Write-Output "COMMAND_PRESERVE_LEN=$commandPreserveLen"
Write-Output "COMMAND_TAIL_OPCODE=$commandTailOpcode"
Write-Output "COMMAND_TAIL_RESULT=$commandTailResult"
Write-Output "COMMAND_TAIL_ARG0=$commandTailArg0"
