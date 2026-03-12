param(
  [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$defaultZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
$zig = if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) { $env:OPENCLAW_ZIG_BIN } else { $defaultZig }
if (-not (Test-Path $zig)) {
  throw "Zig binary not found at '$zig'. Set OPENCLAW_ZIG_BIN to a valid zig executable path."
}
if (-not $SkipBuild) {
  $null = & $zig build --summary all
}

$isWindowsHost = $env:OS -eq "Windows_NT"
$exeCandidates = if ($isWindowsHost) {
  @(
    (Join-Path $repo "zig-out\bin\openclaw-zig.exe"),
    (Join-Path $repo "zig-out/bin/openclaw-zig.exe"),
    (Join-Path $repo "zig-out\bin\openclaw-zig"),
    (Join-Path $repo "zig-out/bin/openclaw-zig")
  )
} else {
  @(
    (Join-Path $repo "zig-out\bin\openclaw-zig"),
    (Join-Path $repo "zig-out/bin/openclaw-zig"),
    (Join-Path $repo "zig-out\bin\openclaw-zig.exe"),
    (Join-Path $repo "zig-out/bin/openclaw-zig.exe")
  )
}
$exe = $null
foreach ($candidate in $exeCandidates) {
  if (Test-Path $candidate) {
    $exe = $candidate
    break
  }
}
if (-not $exe) {
  throw "openclaw-zig executable not found under zig-out/bin after build."
}

function Resolve-FreeTcpPort {
  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  try {
    $listener.Start()
    return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  }
  finally {
    $listener.Stop()
  }
}

function Get-LogTail {
  param(
    [string]$Path,
    [int]$Lines = 120
  )

  if (-not (Test-Path $Path)) { return "" }
  return (Get-Content $Path -Tail $Lines -ErrorAction SilentlyContinue) -join "`n"
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) {
    throw $Message
  }
}

function Assert-Equal {
  param(
    $Actual,
    $Expected,
    [string]$Message
  )

  if ("$Actual" -ne "$Expected") {
    throw "$Message (expected=$Expected actual=$Actual)"
  }
}

function Assert-Contains {
  param(
    [string]$Value,
    [string]$ExpectedSubstring,
    [string]$Message
  )

  if ($Value -notlike "*$ExpectedSubstring*") {
    throw "$Message (expected substring '$ExpectedSubstring' in '$Value')"
  }
}

function Assert-ArrayContains {
  param(
    $Array,
    [string]$ExpectedValue,
    [string]$Message
  )

  $items = @($Array)
  if ($items -notcontains $ExpectedValue) {
    throw "$Message (missing '$ExpectedValue')"
  }
}

function Resolve-RepoPath {
  param([string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return $Path
  }
  return (Join-Path $repo $Path)
}

function Invoke-Rpc {
  param(
    [string]$Method,
    [string]$Id,
    [hashtable]$Params
  )

  $payload = @{
    id = $Id
    method = $Method
    params = $Params
  } | ConvertTo-Json -Depth 20 -Compress

  $response = Invoke-WebRequest -Uri "http://127.0.0.1:$script:Port/rpc" -Method Post -ContentType "application/json" -Body $payload -UseBasicParsing -TimeoutSec 20
  if ($response.StatusCode -ne 200) {
    throw "$Method did not return HTTP 200"
  }

  $json = $response.Content | ConvertFrom-Json
  if (-not $json.result -and $json.chunks -and $json.chunks.Count -ge 1 -and $json.chunks[0].chunk) {
    $json = ($json.chunks[0].chunk | ConvertFrom-Json)
  }

  return @{
    Http = $response
    Content = $response.Content
    Json = $json
  }
}

$script:Port = Resolve-FreeTcpPort
$tempRootName = "tmp_fs5_edge_finetune"
$tempRoot = Join-Path $repo $tempRootName
$stateDir = Join-Path $tempRoot "state"
$datasetRelative = Join-Path $tempRootName "dataset.jsonl"
$datasetPath = Join-Path $repo $datasetRelative
$outputRelative = Join-Path $tempRootName "adapter-output"
$outputPath = Join-Path $repo $outputRelative
$trainerBinary = "builtin:mock-finetune"
$trainerReportPath = Join-Path $outputPath "trainer-report.json"
$adapterFilePath = Join-Path $outputPath "adapter.bin"
$trainerStdoutMarker = "mock finetune trainer completed"
$trainerTimeoutMs = 5000
$stdoutLog = Join-Path $repo "tmp_fs5_edge_finetune_stdout.log"
$stderrLog = Join-Path $repo "tmp_fs5_edge_finetune_stderr.log"

Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
if (Test-Path $tempRoot) {
  Remove-Item $tempRoot -Recurse -Force -ErrorAction Stop
}
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
@'
{"messages":[{"role":"system","content":"finetune smoke dataset"},{"role":"user","content":"teach the adapter to respond consistently"}]}
{"messages":[{"role":"user","content":"What is the smoke adapter?"},{"role":"assistant","content":"A deterministic test adapter for FS5."}]}
'@ | Set-Content -Path $datasetPath -NoNewline

$env:OPENCLAW_ZIG_HTTP_PORT = "$script:Port"
$env:OPENCLAW_ZIG_STATE_PATH = $stateDir
$env:OPENCLAW_ZIG_LORA_TRAINER_BIN = $trainerBinary
$env:OPENCLAW_ZIG_LORA_TRAINER_TIMEOUT_MS = "$trainerTimeoutMs"

$startProcessParams = @{
  FilePath = $exe
  ArgumentList = @("--serve")
  WorkingDirectory = $repo
  PassThru = $true
  RedirectStandardOutput = $stdoutLog
  RedirectStandardError = $stderrLog
}
if ($isWindowsHost) {
  $startProcessParams.WindowStyle = "Hidden"
}
$proc = Start-Process @startProcessParams

$ready = $false
for ($i = 0; $i -lt 60; $i++) {
  if ($proc.HasExited) { break }
  try {
    $health = Invoke-WebRequest -Uri "http://127.0.0.1:$script:Port/health" -UseBasicParsing -TimeoutSec 2
    if ($health.StatusCode -eq 200) {
      $ready = $true
      break
    }
  }
  catch {
    Start-Sleep -Milliseconds 500
  }
}

if (-not $ready) {
  $stderrTail = Get-LogTail -Path $stderrLog -Lines 160
  $stdoutTail = Get-LogTail -Path $stdoutLog -Lines 80
  $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { "running" }
  throw "openclaw-zig server did not become ready on port $script:Port (exit=$exitCode)`nSTDERR:`n$stderrTail`nSTDOUT:`n$stdoutTail"
}

$succeeded = $false
try {
  $statusBefore = Invoke-Rpc -Method "edge.finetune.status" -Id "fs5-ft-status-pre" -Params @{}
  $statusBeforeResult = $statusBefore.Json.result
  Assert-True ($null -ne $statusBeforeResult) "edge.finetune.status pre-run result missing"
  Assert-True ([bool]$statusBeforeResult.supported) "edge.finetune.status supported should be true"
  Assert-Equal $statusBeforeResult.runtimeProfile "edge" "edge.finetune.status runtimeProfile mismatch"
  Assert-Equal $statusBeforeResult.feature "on-device-finetune-self-evolution" "edge.finetune.status feature mismatch"
  Assert-Equal $statusBeforeResult.adapterFormat "lora" "edge.finetune.status adapterFormat mismatch"
  Assert-Equal $statusBeforeResult.trainerBinary $trainerBinary "edge.finetune.status trainerBinary mismatch"
  Assert-Equal ([int]$statusBeforeResult.jobStats.total) 0 "edge.finetune.status pre-run total mismatch"
  Assert-Equal ([int]$statusBeforeResult.jobStats.completed) 0 "edge.finetune.status pre-run completed mismatch"
  Assert-Equal ([int]$statusBeforeResult.jobStats.running) 0 "edge.finetune.status pre-run running mismatch"
  Assert-Equal ([int]$statusBeforeResult.jobStats.failed) 0 "edge.finetune.status pre-run failed mismatch"
  Assert-Equal (@($statusBeforeResult.jobs).Count) 0 "edge.finetune.status pre-run jobs should be empty"

  $runParams = @{
    provider = "chatgpt"
    model = "gpt-5.2"
    adapterName = "fs5-smoke-adapter"
    outputPath = $outputRelative
    datasetPath = $datasetRelative
    epochs = 2
    rank = 16
    learningRate = 0.0003
    maxSamples = 128
    dryRun = $false
    autoIngestMemory = $false
  }
  $run = Invoke-Rpc -Method "edge.finetune.run" -Id "fs5-ft-run" -Params $runParams
  $runResult = $run.Json.result
  Assert-True ($null -ne $runResult) "edge.finetune.run result missing"
  Assert-True ([bool]$runResult.ok) "edge.finetune.run ok should be true"
  Assert-True (-not [bool]$runResult.dryRun) "edge.finetune.run dryRun should be false"
  Assert-Equal $runResult.runtimeProfile "edge" "edge.finetune.run runtimeProfile mismatch"
  Assert-True ([bool]$runResult.execution.attempted) "edge.finetune.run execution.attempted should be true"
  Assert-True ([bool]$runResult.execution.success) "edge.finetune.run execution.success should be true"
  Assert-True (-not [bool]$runResult.execution.timedOut) "edge.finetune.run execution.timedOut should be false"
  Assert-Equal $runResult.execution.status "completed" "edge.finetune.run execution.status mismatch"
  Assert-Equal ([int]$runResult.execution.exitCode) 0 "edge.finetune.run execution.exitCode mismatch"
  Assert-Equal $runResult.execution.binary $trainerBinary "edge.finetune.run execution.binary mismatch"
  Assert-ArrayContains -Array $runResult.execution.argv -ExpectedValue "--dataset" -Message "edge.finetune.run execution.argv missing --dataset"
  Assert-ArrayContains -Array $runResult.execution.argv -ExpectedValue $datasetRelative -Message "edge.finetune.run execution.argv missing dataset path"
  Assert-ArrayContains -Array $runResult.execution.argv -ExpectedValue "--output" -Message "edge.finetune.run execution.argv missing --output"
  Assert-ArrayContains -Array $runResult.execution.argv -ExpectedValue $outputRelative -Message "edge.finetune.run execution.argv missing output path"
  Assert-Contains -Value "$($runResult.execution.logTail.stdout)" -ExpectedSubstring $trainerStdoutMarker -Message "edge.finetune.run execution.logTail.stdout mismatch"
  Assert-Equal $runResult.job.status "completed" "edge.finetune.run job.status mismatch"
  Assert-Equal $runResult.job.statusReason "trainer completed successfully" "edge.finetune.run job.statusReason mismatch"
  Assert-Equal $runResult.job.adapterName "fs5-smoke-adapter" "edge.finetune.run job.adapterName mismatch"
  Assert-Equal $runResult.job.outputPath $outputRelative "edge.finetune.run job.outputPath mismatch"
  Assert-Equal $runResult.job.baseModel.provider "chatgpt" "edge.finetune.run job.baseModel.provider mismatch"
  Assert-Equal $runResult.job.baseModel.id "gpt-5.2" "edge.finetune.run job.baseModel.id mismatch"

  $manifestPath = Resolve-RepoPath -Path "$($runResult.manifestPath)"
  Assert-True (Test-Path $manifestPath) "edge.finetune.run manifestPath file missing"
  Assert-True (Test-Path $adapterFilePath) "edge.finetune.run adapter artifact missing"
  Assert-True (Test-Path $trainerReportPath) "edge.finetune.run trainer report missing"

  $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
  Assert-Equal $manifest.jobId $runResult.jobId "manifest jobId mismatch"
  Assert-Equal $manifest.runtimeProfile "edge" "manifest runtimeProfile mismatch"
  Assert-Equal ([bool]$manifest.dryRun) $false "manifest dryRun mismatch"
  Assert-Equal $manifest.baseModel.provider "chatgpt" "manifest baseModel.provider mismatch"
  Assert-Equal $manifest.baseModel.id "gpt-5.2" "manifest baseModel.id mismatch"
  Assert-Equal $manifest.dataset.path $datasetRelative "manifest dataset.path mismatch"
  Assert-Equal ([bool]$manifest.dataset.autoIngestMemory) $false "manifest dataset.autoIngestMemory mismatch"
  Assert-Equal $manifest.adapter.outputPath $outputRelative "manifest adapter.outputPath mismatch"
  Assert-Equal $manifest.suggestedCommand.binary $trainerBinary "manifest suggestedCommand.binary mismatch"
  Assert-ArrayContains -Array $manifest.suggestedCommand.argv -ExpectedValue "--dataset" -Message "manifest suggestedCommand.argv missing --dataset"
  Assert-ArrayContains -Array $manifest.suggestedCommand.argv -ExpectedValue $datasetRelative -Message "manifest suggestedCommand.argv missing dataset path"
  Assert-ArrayContains -Array $manifest.suggestedCommand.argv -ExpectedValue $outputRelative -Message "manifest suggestedCommand.argv missing output path"
  Assert-Equal ([int]$manifest.suggestedCommand.timeoutMs) $trainerTimeoutMs "manifest timeoutMs mismatch"

  $trainerReport = Get-Content $trainerReportPath -Raw | ConvertFrom-Json
  Assert-Equal $trainerReport.dataset $datasetRelative "trainer report dataset mismatch"
  Assert-Equal $trainerReport.outputPath $outputRelative "trainer report outputPath mismatch"

  $statusAfter = Invoke-Rpc -Method "edge.finetune.status" -Id "fs5-ft-status-post" -Params @{}
  $statusAfterResult = $statusAfter.Json.result
  Assert-Equal ([int]$statusAfterResult.jobStats.total) 1 "edge.finetune.status post-run total mismatch"
  Assert-Equal ([int]$statusAfterResult.jobStats.completed) 1 "edge.finetune.status post-run completed mismatch"
  Assert-Equal ([int]$statusAfterResult.jobStats.running) 0 "edge.finetune.status post-run running mismatch"
  Assert-Equal ([int]$statusAfterResult.jobStats.failed) 0 "edge.finetune.status post-run failed mismatch"
  Assert-Equal (@($statusAfterResult.jobs).Count) 1 "edge.finetune.status post-run jobs length mismatch"
  Assert-Equal $statusAfterResult.jobs[0].id $runResult.jobId "edge.finetune.status post-run job id mismatch"
  Assert-Equal $statusAfterResult.jobs[0].status "completed" "edge.finetune.status post-run job status mismatch"

  $jobGet = Invoke-Rpc -Method "edge.finetune.job.get" -Id "fs5-ft-job-get" -Params @{ jobId = $runResult.jobId }
  $jobGetResult = $jobGet.Json.result
  Assert-True ([bool]$jobGetResult.ok) "edge.finetune.job.get ok should be true"
  Assert-Equal $jobGetResult.job.id $runResult.jobId "edge.finetune.job.get job id mismatch"
  Assert-Equal $jobGetResult.job.status "completed" "edge.finetune.job.get status mismatch"
  Assert-Equal $jobGetResult.job.statusReason "trainer completed successfully" "edge.finetune.job.get statusReason mismatch"
  Assert-Equal $jobGetResult.job.manifestPath $runResult.manifestPath "edge.finetune.job.get manifestPath mismatch"

  $cancel = Invoke-Rpc -Method "edge.finetune.cancel" -Id "fs5-ft-cancel" -Params @{ jobId = $runResult.jobId }
  $cancelResult = $cancel.Json.result
  Assert-True ([bool]$cancelResult.ok) "edge.finetune.cancel ok should be true"
  Assert-True (-not [bool]$cancelResult.canceled) "edge.finetune.cancel canceled should be false for completed job"
  Assert-Equal $cancelResult.status "completed" "edge.finetune.cancel status mismatch"
  Assert-Equal $cancelResult.statusReason "trainer completed successfully" "edge.finetune.cancel statusReason mismatch"
  Assert-Equal "$($cancelResult.updatedAtMs)" "$($jobGetResult.job.updatedAtMs)" "edge.finetune.cancel updatedAtMs mismatch"

  $jobGetAfterCancel = Invoke-Rpc -Method "edge.finetune.job.get" -Id "fs5-ft-job-get-after-cancel" -Params @{ jobId = $runResult.jobId }
  $jobGetAfterCancelResult = $jobGetAfterCancel.Json.result
  Assert-Equal $jobGetAfterCancelResult.job.id $runResult.jobId "edge.finetune.job.get after cancel job id mismatch"
  Assert-Equal $jobGetAfterCancelResult.job.status "completed" "edge.finetune.job.get after cancel status mismatch"
  Assert-Equal $jobGetAfterCancelResult.job.statusReason "trainer completed successfully" "edge.finetune.job.get after cancel statusReason mismatch"
  Assert-Equal "$($jobGetAfterCancelResult.job.updatedAtMs)" "$($cancelResult.updatedAtMs)" "edge.finetune.job.get after cancel updatedAtMs mismatch"

  Write-Output "EDGE_FINETUNE_STATUS_PRE_TOTAL=$($statusBeforeResult.jobStats.total)"
  Write-Output "EDGE_FINETUNE_RUN_HTTP=$($run.Http.StatusCode)"
  Write-Output "EDGE_FINETUNE_RUN_JOB_ID=$($runResult.jobId)"
  Write-Output "EDGE_FINETUNE_RUN_STATUS=$($runResult.job.status)"
  Write-Output "EDGE_FINETUNE_RUN_EXECUTION_STATUS=$($runResult.execution.status)"
  Write-Output "EDGE_FINETUNE_RUN_MANIFEST_PATH=$($runResult.manifestPath)"
  Write-Output "EDGE_FINETUNE_STATUS_POST_TOTAL=$($statusAfterResult.jobStats.total)"
  Write-Output "EDGE_FINETUNE_STATUS_POST_COMPLETED=$($statusAfterResult.jobStats.completed)"
  Write-Output "EDGE_FINETUNE_JOB_GET_STATUS=$($jobGetResult.job.status)"
  Write-Output "EDGE_FINETUNE_CANCEL_STATUS=$($cancelResult.status)"
  Write-Output "EDGE_FINETUNE_CANCEL_CANCELED=$($cancelResult.canceled)"
  Write-Output "EDGE_FINETUNE_POST_CANCEL_STATUS=$($jobGetAfterCancelResult.job.status)"

  $succeeded = $true
}
finally {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_STATE_PATH -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_LORA_TRAINER_BIN -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_LORA_TRAINER_TIMEOUT_MS -ErrorAction SilentlyContinue
  if ($succeeded) {
    Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
    if (Test-Path $tempRoot) {
      Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
