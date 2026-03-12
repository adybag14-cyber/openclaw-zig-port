param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'
function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

function Invoke-Probe {
    param(
        [string] $Path,
        [hashtable] $Arguments,
        [string] $SuccessToken,
        [string] $SkipToken,
        [string] $Label
    )

    if (-not (Test-Path $Path)) { throw "$Label script not found: $Path" }

    $output = & $Path @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String)

    if ($text -match ('(?m)^' + [regex]::Escape($SkipToken) + '=skipped\r?$')) {
        return @{ Status = 'skipped'; Text = $text }
    }

    if ($exitCode -ne 0) {
        if ($text) { Write-Output $text.TrimEnd() }
        throw "$Label failed with exit code $exitCode"
    }

    if ($text -notmatch ('(?m)^' + [regex]::Escape($SuccessToken) + '=pass\r?$')) {
        if ($text) { Write-Output $text.TrimEnd() }
        throw "$Label did not report a pass token"
    }

    return @{ Status = 'pass'; Text = $text }
}
$args = @{ TimeoutSeconds = $TimeoutSeconds }
if ($SkipBuild) { $args.SkipBuild = $true }

$overflow = Invoke-Probe -Path (Join-Path $PSScriptRoot 'baremetal-qemu-command-health-history-probe-check.ps1') -Arguments $args -SuccessToken 'BAREMETAL_QEMU_COMMAND_HEALTH_HISTORY_PROBE' -SkipToken 'BAREMETAL_QEMU_COMMAND_HEALTH_HISTORY_PROBE' -Label 'command-health history probe'
if ($overflow.Status -eq 'skipped') {
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-command-health-history-probe-check.ps1,baremetal-qemu-bootdiag-history-clear-probe-check.ps1'
    exit 0
}

$clear = Invoke-Probe -Path (Join-Path $PSScriptRoot 'baremetal-qemu-bootdiag-history-clear-probe-check.ps1') -Arguments $args -SuccessToken 'BAREMETAL_QEMU_BOOTDIAG_HISTORY_CLEAR_PROBE' -SkipToken 'BAREMETAL_QEMU_BOOTDIAG_HISTORY_CLEAR_PROBE' -Label 'bootdiag/history clear probe'
if ($clear.Status -eq 'skipped') {
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-command-health-history-probe-check.ps1,baremetal-qemu-bootdiag-history-clear-probe-check.ps1'
    exit 0
}

$overflowCount = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_OVERFLOW'
$firstSeq = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_FIRST_SEQ'
$firstCode = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_FIRST_CODE'
$firstAck = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_FIRST_ACK'
$prevLastSeq = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_PREV_LAST_SEQ'
$prevLastCode = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_PREV_LAST_CODE'
$prevLastAck = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_PREV_LAST_ACK'
$lastSeq = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_LAST_SEQ'
$lastCode = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_LAST_CODE'
$lastAck = Extract-IntValue -Text $overflow.Text -Name 'HEALTH_HISTORY_LAST_ACK'
$clearLen = Extract-IntValue -Text $clear.Text -Name 'HEALTH_HISTORY_LEN'
$clearFirstSeq = Extract-IntValue -Text $clear.Text -Name 'HEALTH_HISTORY_FIRST_SEQ'
$clearFirstCode = Extract-IntValue -Text $clear.Text -Name 'HEALTH_HISTORY_FIRST_CODE'
$clearFirstMode = Extract-IntValue -Text $clear.Text -Name 'HEALTH_HISTORY_FIRST_MODE'
$clearFirstTick = Extract-IntValue -Text $clear.Text -Name 'HEALTH_HISTORY_FIRST_TICK'
$clearFirstAck = Extract-IntValue -Text $clear.Text -Name 'HEALTH_HISTORY_FIRST_ACK'
$commandPreserveLen = Extract-IntValue -Text $clear.Text -Name 'CMD_HISTORY_LEN3'
$commandTailOpcode = Extract-IntValue -Text $clear.Text -Name 'CMD_HISTORY_SECOND_OPCODE'
$commandTailResult = Extract-IntValue -Text $clear.Text -Name 'CMD_HISTORY_SECOND_RESULT'
$commandTailArg0 = Extract-IntValue -Text $clear.Text -Name 'CMD_HISTORY_SECOND_ARG0'

if (
    $overflowCount -ne 7 -or
    $firstSeq -ne 8 -or
    $firstCode -ne 103 -or
    $firstAck -ne 3 -or
    $prevLastSeq -ne 70 -or
    $prevLastCode -ne 134 -or
    $prevLastAck -ne 34 -or
    $lastSeq -ne 71 -or
    $lastCode -ne 200 -or
    $lastAck -ne 35 -or
    $clearLen -ne 1 -or
    $clearFirstSeq -ne 1 -or
    $clearFirstCode -ne 200 -or
    $clearFirstMode -ne 1 -or
    $clearFirstTick -ne 6 -or
    $clearFirstAck -ne 6 -or
    $commandPreserveLen -ne 2 -or
    $commandTailOpcode -ne 20 -or
    $commandTailResult -ne 0 -or
    $commandTailArg0 -ne 0
) {
    throw "Unexpected health-history overflow/clear values: overflow=$overflowCount firstSeq=$firstSeq firstCode=$firstCode firstAck=$firstAck prevLastSeq=$prevLastSeq prevLastCode=$prevLastCode prevLastAck=$prevLastAck lastSeq=$lastSeq lastCode=$lastCode lastAck=$lastAck clearLen=$clearLen clearFirstSeq=$clearFirstSeq clearFirstCode=$clearFirstCode clearFirstMode=$clearFirstMode clearFirstTick=$clearFirstTick clearFirstAck=$clearFirstAck commandPreserveLen=$commandPreserveLen commandTailOpcode=$commandTailOpcode commandTailResult=$commandTailResult commandTailArg0=$commandTailArg0"
}

Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-command-health-history-probe-check.ps1,baremetal-qemu-bootdiag-history-clear-probe-check.ps1'
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_OVERFLOW_COUNT=$overflowCount"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_SEQ=$firstSeq"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_CODE=$firstCode"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_ACK=$firstAck"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_PREV_LAST_SEQ=$prevLastSeq"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_PREV_LAST_CODE=$prevLastCode"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_PREV_LAST_ACK=$prevLastAck"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_SEQ=$lastSeq"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_CODE=$lastCode"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_ACK=$lastAck"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_LEN=$clearLen"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_SEQ=$clearFirstSeq"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_CODE=$clearFirstCode"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_MODE=$clearFirstMode"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_TICK=$clearFirstTick"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_FIRST_ACK=$clearFirstAck"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_PRESERVE_LEN=$commandPreserveLen"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_TAIL_OPCODE=$commandTailOpcode"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_TAIL_RESULT=$commandTailResult"
Write-Output "BAREMETAL_QEMU_HEALTH_HISTORY_OVERFLOW_CLEAR_PROBE_COMMAND_TAIL_ARG0=$commandTailArg0"
