param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-reason-vector-pop-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FIRST_MATCH_PROBE=skipped'

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
$task3Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK3_ID'
$task4Id = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_TASK4_ID'
$midCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_COUNT'
$midTask0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_TASK0'
$midTask1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_TASK1'
$midTask2 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_TASK2'
$midVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_VECTOR0'
$midVector1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_VECTOR1'
$midVector2 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_MID_VECTOR2'
if ($null -in @($task1Id,$task3Id,$task4Id,$midCount,$midTask0,$midTask1,$midTask2,$midVector0,$midVector1,$midVector2)) {
    throw 'Missing expected first-match fields in wake-queue reason-vector-pop probe output.'
}
if ($midCount -ne 3) { throw "Expected MID_COUNT=3. got $midCount" }
if ($midTask0 -ne $task1Id -or $midTask1 -ne $task3Id -or $midTask2 -ne $task4Id) {
    throw "Unexpected first-match task ordering: $midTask0,$midTask1,$midTask2"
}
if ($midVector0 -ne 0 -or $midVector1 -ne 13 -or $midVector2 -ne 19) {
    throw "Unexpected first-match vector ordering: $midVector0,$midVector1,$midVector2"
}
Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_FIRST_MATCH_PROBE=pass'
Write-Output "MID_COUNT=$midCount"
Write-Output "MID_TASK0=$midTask0"
Write-Output "MID_TASK1=$midTask1"
Write-Output "MID_TASK2=$midTask2"
Write-Output "MID_VECTOR0=$midVector0"
Write-Output "MID_VECTOR1=$midVector1"
Write-Output "MID_VECTOR2=$midVector2"
