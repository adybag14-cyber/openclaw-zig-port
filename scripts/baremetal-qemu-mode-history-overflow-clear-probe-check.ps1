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

$overflow = Invoke-Probe -Path (Join-Path $PSScriptRoot 'baremetal-qemu-mode-boot-phase-history-probe-check.ps1') -Arguments $args -SuccessToken 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_PROBE' -SkipToken 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_PROBE' -Label 'mode/boot-phase history probe'
if ($overflow.Status -eq 'skipped') {
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-probe-check.ps1,baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
    exit 0
}

$clear = Invoke-Probe -Path (Join-Path $PSScriptRoot 'baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1') -Arguments $args -SuccessToken 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PROBE' -SkipToken 'BAREMETAL_QEMU_MODE_BOOT_PHASE_HISTORY_CLEAR_PROBE' -Label 'mode/boot-phase history clear probe'
if ($clear.Status -eq 'skipped') {
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-probe-check.ps1,baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
    exit 0
}

$overflowCount = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_OVERFLOW'
$overflowHead = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_HEAD'
$firstSeq = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_FIRST_SEQ'
$firstPrev = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_FIRST_PREV'
$firstNew = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_FIRST_NEW'
$firstReason = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_FIRST_REASON'
$lastSeq = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_LAST_SEQ'
$lastPrev = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_LAST_PREV'
$lastNew = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_LAST_NEW'
$lastReason = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_LAST_REASON'
$clearLen = Extract-IntValue -Text $clear.Text -Name 'POST_CLEAR_MODE_LEN'
$clearHead = Extract-IntValue -Text $clear.Text -Name 'POST_CLEAR_MODE_HEAD'
$clearOverflow = Extract-IntValue -Text $clear.Text -Name 'POST_CLEAR_MODE_OVERFLOW'
$clearSeq = Extract-IntValue -Text $clear.Text -Name 'POST_CLEAR_MODE_SEQ'
$bootPreserveLen = Extract-IntValue -Text $clear.Text -Name 'POST_CLEAR_BOOT_LEN_AFTER_MODE_CLEAR'
$restartLen = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE_LEN'
$restartHead = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE_HEAD'
$restartOverflow = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE_OVERFLOW'
$restartSeq = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE_SEQ'
$restartFirstSeq = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE0_SEQ'
$restartFirstPrev = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE0_PREV'
$restartFirstNew = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE0_NEW'
$restartFirstReason = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE0_REASON'
$restartSecondSeq = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE1_SEQ'
$restartSecondPrev = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE1_PREV'
$restartSecondNew = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE1_NEW'
$restartSecondReason = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE1_REASON'

if (
    $overflowCount -ne 2 -or $overflowHead -ne 2 -or
    $firstSeq -ne 3 -or $firstPrev -ne 1 -or $firstNew -ne 0 -or $firstReason -ne 1 -or
    $lastSeq -ne 66 -or $lastPrev -ne 0 -or $lastNew -ne 1 -or $lastReason -ne 3 -or
    $clearLen -ne 0 -or $clearHead -ne 0 -or $clearOverflow -ne 0 -or $clearSeq -ne 0 -or $bootPreserveLen -ne 3 -or
    $restartLen -ne 2 -or $restartHead -ne 2 -or $restartOverflow -ne 0 -or $restartSeq -ne 2 -or
    $restartFirstSeq -ne 1 -or $restartFirstPrev -ne 1 -or $restartFirstNew -ne 0 -or $restartFirstReason -ne 1 -or
    $restartSecondSeq -ne 2 -or $restartSecondPrev -ne 0 -or $restartSecondNew -ne 1 -or $restartSecondReason -ne 3
) {
    throw "Unexpected mode-history overflow/clear values: overflow=$overflowCount head=$overflowHead first=$firstSeq/$firstPrev->$($firstNew):$firstReason last=$lastSeq/$lastPrev->$($lastNew):$lastReason clearLen=$clearLen clearHead=$clearHead clearOverflow=$clearOverflow clearSeq=$clearSeq bootPreserveLen=$bootPreserveLen restartLen=$restartLen restartHead=$restartHead restartOverflow=$restartOverflow restartSeq=$restartSeq restartFirst=$restartFirstSeq/$restartFirstPrev->$($restartFirstNew):$restartFirstReason restartSecond=$restartSecondSeq/$restartSecondPrev->$($restartSecondNew):$restartSecondReason"
}

Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-probe-check.ps1,baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_OVERFLOW_COUNT=$overflowCount"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_OVERFLOW_HEAD=$overflowHead"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_SEQ=$firstSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_PREV=$firstPrev"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_NEW=$firstNew"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_REASON=$firstReason"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_SEQ=$lastSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_PREV=$lastPrev"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_NEW=$lastNew"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_REASON=$lastReason"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_LEN=$clearLen"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_HEAD=$clearHead"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_OVERFLOW=$clearOverflow"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_SEQ=$clearSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_BOOT_PRESERVE_LEN=$bootPreserveLen"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_LEN=$restartLen"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_HEAD=$restartHead"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_OVERFLOW=$restartOverflow"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SEQ=$restartSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_SEQ=$restartFirstSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_PREV=$restartFirstPrev"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_NEW=$restartFirstNew"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_REASON=$restartFirstReason"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_SEQ=$restartSecondSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_PREV=$restartSecondPrev"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_NEW=$restartSecondNew"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_SECOND_REASON=$restartSecondReason"
