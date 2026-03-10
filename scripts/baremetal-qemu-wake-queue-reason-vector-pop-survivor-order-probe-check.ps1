param(
    [switch] $SkipBuild
)

$ErrorActionPreference = "Stop"
$probe = Join-Path $PSScriptRoot "baremetal-qemu-wake-queue-reason-vector-pop-probe-check.ps1"
$skipToken = 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_SURVIVOR_ORDER_PROBE=skipped'

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
$postCount = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_COUNT'
$postTask0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_TASK0'
$postTask1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_TASK1'
$postVector0 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_VECTOR0'
$postVector1 = Extract-IntValue -Text $probeText -Name 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_POST_VECTOR1'
if ($null -in @($task1Id,$task4Id,$postCount,$postTask0,$postTask1,$postVector0,$postVector1)) {
    throw 'Missing expected survivor-order fields in wake-queue reason-vector-pop probe output.'
}
if ($postCount -ne 2) { throw "Expected POST_COUNT=2. got $postCount" }
if ($postTask0 -ne $task1Id -or $postTask1 -ne $task4Id) {
    throw "Unexpected survivor task ordering: $postTask0,$postTask1"
}
if ($postVector0 -ne 0 -or $postVector1 -ne 19) {
    throw "Unexpected survivor vector ordering: $postVector0,$postVector1"
}
Write-Output 'BAREMETAL_QEMU_WAKE_QUEUE_REASON_VECTOR_POP_SURVIVOR_ORDER_PROBE=pass'
Write-Output "POST_COUNT=$postCount"
Write-Output "POST_TASK0=$postTask0"
Write-Output "POST_TASK1=$postTask1"
Write-Output "POST_VECTOR0=$postVector0"
Write-Output "POST_VECTOR1=$postVector1"
