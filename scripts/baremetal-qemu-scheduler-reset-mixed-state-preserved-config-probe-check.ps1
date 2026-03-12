param(
    [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'
$probe = Join-Path $PSScriptRoot 'baremetal-qemu-scheduler-reset-mixed-state-probe-check.ps1'

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PRESERVED_CONFIG_PROBE=skipped'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying scheduler-reset mixed-state probe failed with exit code $probeExitCode"
}

$postNextTimerId = Extract-IntValue -Text $probeText -Name 'POST_NEXT_TIMER_ID'
$postQuantum = Extract-IntValue -Text $probeText -Name 'POST_QUANTUM'

if ($null -in @($postNextTimerId, $postQuantum)) {
    throw 'Missing expected scheduler-reset mixed-state preserved-config fields in probe output.'
}
if ($postNextTimerId -ne 2) { throw "Expected POST_NEXT_TIMER_ID=2. got $postNextTimerId" }
if ($postQuantum -ne 5) { throw "Expected POST_QUANTUM=5. got $postQuantum" }

Write-Output 'BAREMETAL_QEMU_SCHEDULER_RESET_MIXED_STATE_PRESERVED_CONFIG_PROBE=pass'
Write-Output "POST_NEXT_TIMER_ID=$postNextTimerId"
Write-Output "POST_QUANTUM=$postQuantum"
