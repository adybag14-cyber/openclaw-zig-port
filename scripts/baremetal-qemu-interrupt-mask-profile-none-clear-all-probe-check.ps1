param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 40,
    [int] $GdbPort = 1348
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-interrupt-mask-profile-probe-check.ps1"
if (-not (Test-Path $probe)) { throw "Prerequisite probe not found: $probe" }

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $match = [regex]::Match($Text, '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$')
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$invoke = @{ TimeoutSeconds = $TimeoutSeconds; GdbPort = $GdbPort }
if ($SkipBuild) { $invoke.SkipBuild = $true }

$probeOutput = & $probe @invoke 2>&1
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
if ($probeText -match '(?m)^BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE=skipped\r?$') {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_NONE_CLEAR_ALL_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_NONE_CLEAR_ALL_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying interrupt-mask-profile probe failed with exit code $probeExitCode"
}

$noneProfile = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_NONE_PROFILE'
$noneMaskedCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_NONE_MASKED_COUNT'
$finalProfile = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_INTERRUPT_MASK_PROFILE'
$finalMaskedCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_INTERRUPT_MASKED_COUNT'
$finalIgnoredCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_MASKED_INTERRUPT_IGNORED_COUNT'
$finalLastMaskedVector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_LAST_MASKED_INTERRUPT_VECTOR'
$schedTaskCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_SCHED_TASK_COUNT'
$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_TASK0_STATE'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_WAKE_QUEUE_COUNT'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_WAKE0_VECTOR'
$wake0Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_WAKE0_REASON'
if ($null -in @($noneProfile, $noneMaskedCount, $finalProfile, $finalMaskedCount, $finalIgnoredCount, $finalLastMaskedVector, $schedTaskCount, $task0State, $wakeQueueCount, $wake0Vector, $wake0Reason)) {
    throw 'Missing expected none/clear-all fields in probe output.'
}
if ($noneProfile -ne 0) { throw "Expected NONE_PROFILE=0. got $noneProfile" }
if ($noneMaskedCount -ne 0) { throw "Expected NONE_MASKED_COUNT=0. got $noneMaskedCount" }
if ($finalProfile -ne 0) { throw "Expected INTERRUPT_MASK_PROFILE=0. got $finalProfile" }
if ($finalMaskedCount -ne 0) { throw "Expected INTERRUPT_MASKED_COUNT=0. got $finalMaskedCount" }
if ($finalIgnoredCount -ne 0) { throw "Expected MASKED_INTERRUPT_IGNORED_COUNT=0. got $finalIgnoredCount" }
if ($finalLastMaskedVector -ne 0) { throw "Expected LAST_MASKED_INTERRUPT_VECTOR=0. got $finalLastMaskedVector" }
if ($schedTaskCount -ne 1) { throw "Expected SCHED_TASK_COUNT=1. got $schedTaskCount" }
if ($task0State -ne 1) { throw "Expected TASK0_STATE=1. got $task0State" }
if ($wakeQueueCount -ne 1) { throw "Expected WAKE_QUEUE_COUNT=1. got $wakeQueueCount" }
if ($wake0Vector -ne 200) { throw "Expected WAKE0_VECTOR=200. got $wake0Vector" }
if ($wake0Reason -ne 2) { throw "Expected WAKE0_REASON=2. got $wake0Reason" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_NONE_CLEAR_ALL_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_NONE_CLEAR_ALL_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
Write-Output "NONE_PROFILE=$noneProfile"
Write-Output "NONE_MASKED_COUNT=$noneMaskedCount"
Write-Output "INTERRUPT_MASK_PROFILE=$finalProfile"
Write-Output "INTERRUPT_MASKED_COUNT=$finalMaskedCount"
Write-Output "MASKED_INTERRUPT_IGNORED_COUNT=$finalIgnoredCount"
Write-Output "LAST_MASKED_INTERRUPT_VECTOR=$finalLastMaskedVector"
Write-Output "SCHED_TASK_COUNT=$schedTaskCount"
Write-Output "TASK0_STATE=$task0State"
Write-Output "WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "WAKE0_VECTOR=$wake0Vector"
Write-Output "WAKE0_REASON=$wake0Reason"
