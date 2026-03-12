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
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_UNMASK_RECOVERY_PROBE=skipped'
    Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_UNMASK_RECOVERY_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
    exit 0
}
if ($probeExitCode -ne 0) {
    if ($probeText) { Write-Output $probeText.TrimEnd() }
    throw "Underlying interrupt-mask-profile probe failed with exit code $probeExitCode"
}

$task0State = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_UNMASK_TASK0_STATE'
$wakeQueueCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_UNMASK_WAKE_QUEUE_COUNT'
$wake0Vector = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_UNMASK_WAKE0_VECTOR'
$wake0Reason = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_UNMASK_WAKE0_REASON'
$profile = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_UNMASK_PROFILE'
$maskedCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_UNMASK_MASKED_COUNT'
$masked200 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_PROBE_UNMASK_MASKED_200'
if ($null -in @($task0State, $wakeQueueCount, $wake0Vector, $wake0Reason, $profile, $maskedCount, $masked200)) {
    throw 'Missing expected unmask-recovery fields in probe output.'
}
if ($task0State -ne 1) { throw "Expected UNMASK_TASK0_STATE=1. got $task0State" }
if ($wakeQueueCount -ne 1) { throw "Expected UNMASK_WAKE_QUEUE_COUNT=1. got $wakeQueueCount" }
if ($wake0Vector -ne 200) { throw "Expected UNMASK_WAKE0_VECTOR=200. got $wake0Vector" }
if ($wake0Reason -ne 2) { throw "Expected UNMASK_WAKE0_REASON=2. got $wake0Reason" }
if ($profile -ne 255) { throw "Expected UNMASK_PROFILE=255. got $profile" }
if ($maskedCount -ne 223) { throw "Expected UNMASK_MASKED_COUNT=223. got $maskedCount" }
if ($masked200 -ne 0) { throw "Expected UNMASK_MASKED_200=0. got $masked200" }

Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_UNMASK_RECOVERY_PROBE=pass'
Write-Output 'BAREMETAL_QEMU_INTERRUPT_MASK_PROFILE_UNMASK_RECOVERY_PROBE_SOURCE=baremetal-qemu-interrupt-mask-profile-probe-check.ps1'
Write-Output "UNMASK_TASK0_STATE=$task0State"
Write-Output "UNMASK_WAKE_QUEUE_COUNT=$wakeQueueCount"
Write-Output "UNMASK_WAKE0_VECTOR=$wake0Vector"
Write-Output "UNMASK_WAKE0_REASON=$wake0Reason"
Write-Output "UNMASK_PROFILE=$profile"
Write-Output "UNMASK_MASKED_COUNT=$maskedCount"
Write-Output "UNMASK_MASKED_200=$masked200"
