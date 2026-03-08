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
$firstSeq = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_FIRST_SEQ'
$lastSeq = Extract-IntValue -Text $overflow.Text -Name 'MODE_HISTORY_LAST_SEQ'
$clearLen = Extract-IntValue -Text $clear.Text -Name 'POST_CLEAR_MODE_LEN'
$restartLen = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE_LEN'
$restartFirstSeq = Extract-IntValue -Text $clear.Text -Name 'RESET_MODE0_SEQ'

if ($overflowCount -ne 2 -or $firstSeq -ne 3 -or $lastSeq -ne 66 -or $clearLen -ne 0 -or $restartLen -ne 2 -or $restartFirstSeq -ne 1) {
    throw "Unexpected mode-history overflow/clear values: overflow=$overflowCount first=$firstSeq last=$lastSeq clearLen=$clearLen restartLen=$restartLen restartFirst=$restartFirstSeq"
}

Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_SOURCE=baremetal-qemu-mode-boot-phase-history-probe-check.ps1,baremetal-qemu-mode-boot-phase-history-clear-probe-check.ps1'
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_OVERFLOW_COUNT=$overflowCount"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_FIRST_SEQ=$firstSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_LAST_SEQ=$lastSeq"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_CLEAR_LEN=$clearLen"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_LEN=$restartLen"
Write-Output "BAREMETAL_QEMU_MODE_HISTORY_OVERFLOW_CLEAR_PROBE_RESTART_FIRST_SEQ=$restartFirstSeq"
