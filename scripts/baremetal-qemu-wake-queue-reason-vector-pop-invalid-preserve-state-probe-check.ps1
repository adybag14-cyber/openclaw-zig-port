param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-reason-vector-pop-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_INVALID_PRESERVE_STATE_PROBE=skipped'

function Extract-IntValue {
    param([string] $Text, [string] $Name)
    $pattern = '(?m)^' + [regex]::Escape($Name) + '=(-?\d+)\r?$'
    $match = [regex]::Match($Text, $pattern)
    if (-not $match.Success) { return $null }
    return [int64]::Parse($match.Groups[1].Value)
}

$probeOutput = if ($SkipBuild) { & $probe -SkipBuild 2>&1 } else { & $probe 2>&1 }
$probeExitCode = $LASTEXITCODE
$probeText = ($probeOutput | Out-String)
$probeOutput | Write-Output
if ($probeText -match 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_PROBE=skipped') {
    Write-Output $skipToken
    exit 0
}
if ($probeExitCode -ne 0) {
    throw "Underlying wake-queue reason-vector-pop probe failed with exit code $probeExitCode"
}

$task1Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK1_ID'
$task4Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK4_ID'
$finalCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_COUNT'
$finalTask0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_TASK0'
$finalTask1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_TASK1'
$finalVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_VECTOR0'
$finalVector1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FINAL_VECTOR1'
if ($null -in @($task1Id,$task4Id,$finalCount,$finalTask0,$finalTask1,$finalVector0,$finalVector1)) {
    throw 'Missing expected invalid-preserve-state fields in wake-queue reason-vector-pop probe output.'
}
if ($finalCount -ne 2) { throw "Expected FINAL_COUNT=2. got $finalCount" }
if ($finalTask0 -ne $task1Id -or $finalTask1 -ne $task4Id) {
    throw "Unexpected final preserved task ordering: $finalTask0,$finalTask1"
}
if ($finalVector0 -ne 0 -or $finalVector1 -ne 19) {
    throw "Unexpected final preserved vector ordering: $finalVector0,$finalVector1"
}
Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_INVALID_PRESERVE_STATE_PROBE=pass'
Write-Output "FINAL_COUNT=$finalCount"
Write-Output "FINAL_TASK0=$finalTask0"
Write-Output "FINAL_TASK1=$finalTask1"
Write-Output "FINAL_VECTOR0=$finalVector0"
Write-Output "FINAL_VECTOR1=$finalVector1"
