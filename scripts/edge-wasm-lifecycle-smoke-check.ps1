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

function Get-Sha256Hex {
  param([string]$Text)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
  }
  finally {
    $sha.Dispose()
  }
  return (-join ($hash | ForEach-Object { $_.ToString("x2") }))
}

function Get-HmacSha256Hex {
  param(
    [string]$Text,
    [string]$Key
  )

  $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($Key)
  $textBytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
  $hmac = [System.Security.Cryptography.HMACSHA256]::new($keyBytes)
  try {
    $hash = $hmac.ComputeHash($textBytes)
  }
  finally {
    $hmac.Dispose()
  }
  return (-join ($hash | ForEach-Object { $_.ToString("x2") }))
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

  $response = Invoke-WebRequest -Uri "http://127.0.0.1:$script:Port/rpc" -Method Post -ContentType "application/json" -Body $payload -UseBasicParsing -TimeoutSec 10
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

$script:Port = 8096
$trustKey = "fs5-smoke-trust-key"
$moduleId = "wasm.custom.fs5.smoke"
$version = "0.2.0"
$description = "FS5 trusted smoke module"
$capabilities = @("workspace.read")
$capabilitiesCsv = ($capabilities -join ",")
$sourceUrl = "https://example.invalid/fs5.wasm"
$signer = "fs5-smoke"

$stateDir = Join-Path $repo "tmp_fs5_edge_wasm_state"
$stdoutLog = Join-Path $repo "tmp_fs5_edge_wasm_stdout.log"
$stderrLog = Join-Path $repo "tmp_fs5_edge_wasm_stderr.log"
Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
if (Test-Path $stateDir) {
  Remove-Item $stateDir -Recurse -Force -ErrorAction Stop
}
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

$env:OPENCLAW_ZIG_HTTP_PORT = "$script:Port"
$env:OPENCLAW_ZIG_WASM_TRUST_KEY = $trustKey
$env:OPENCLAW_ZIG_WASM_TRUST_POLICY = "signature"
$env:OPENCLAW_ZIG_STATE_PATH = $stateDir

$digestSource = "moduleId=$moduleId;version=$version;description=$description;capabilities=$capabilitiesCsv;source=$sourceUrl"
$digestSha256 = Get-Sha256Hex -Text $digestSource
$signature = Get-HmacSha256Hex -Text $digestSha256 -Key $trustKey

$badModuleId = "wasm.custom.fs5.bad-signature"
$badDigestSource = "moduleId=$badModuleId;version=$version;description=$description;capabilities=$capabilitiesCsv;source=$sourceUrl"
$badDigestSha256 = Get-Sha256Hex -Text $badDigestSource

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

try {
  $list1 = Invoke-Rpc -Method "edge.wasm.marketplace.list" -Id "fs5-wasm-list-1" -Params @{}
  $list1Result = $list1.Json.result
  Assert-True ($null -ne $list1Result) "edge.wasm.marketplace.list result missing"
  $builtinModules = @()
  if ($null -ne $list1Result.modules) { $builtinModules = @($list1Result.modules) }
  $builtinIds = @($builtinModules | ForEach-Object { $_.id })
  Assert-True ($builtinIds -contains "wasm.echo") "built-in wasm.echo module missing"
  Assert-Equal $list1Result.customModuleCount 0 "initial customModuleCount mismatch"
  Assert-True ([int]$list1Result.moduleCount -ge 3) "initial moduleCount should include built-ins"

  $install = Invoke-Rpc -Method "edge.wasm.install" -Id "fs5-wasm-install" -Params @{
    moduleId = $moduleId
    version = $version
    description = $description
    capabilities = $capabilities
    sourceUrl = $sourceUrl
    sha256 = $digestSha256
    signature = $signature
    signer = $signer
    requireSignature = $true
    trustPolicy = "signature"
  }
  $installResult = $install.Json.result
  Assert-True ($null -ne $installResult) "edge.wasm.install result missing"
  Assert-Equal $installResult.status "installed" "edge.wasm.install status mismatch"
  Assert-Equal $installResult.module.id $moduleId "edge.wasm.install module id mismatch"
  Assert-Equal $installResult.module.version $version "edge.wasm.install version mismatch"
  Assert-Equal $installResult.module.sha256 $digestSha256 "edge.wasm.install digest mismatch"
  Assert-Equal $installResult.module.signature $signature "edge.wasm.install signature mismatch"
  Assert-Equal $installResult.module.signer $signer "edge.wasm.install signer mismatch"
  Assert-True ([bool]$installResult.module.verified) "edge.wasm.install verified should be true"
  Assert-Equal $installResult.module.verificationMode "hmac-sha256" "edge.wasm.install verificationMode mismatch"
  Assert-Equal $installResult.trustPolicy "signature" "edge.wasm.install trustPolicy mismatch"
  Assert-Equal $installResult.customModuleCount 1 "edge.wasm.install customModuleCount mismatch"

  $list2 = Invoke-Rpc -Method "edge.wasm.marketplace.list" -Id "fs5-wasm-list-2" -Params @{}
  $list2Result = $list2.Json.result
  Assert-Equal $list2Result.customModuleCount 1 "post-install customModuleCount mismatch"
  $customModules = @()
  if ($null -ne $list2Result.customModules) { $customModules = @($list2Result.customModules) }
  $installedModule = $customModules | Where-Object { $_.id -eq $moduleId } | Select-Object -First 1
  Assert-True ($null -ne $installedModule) "installed custom module missing from marketplace.list"
  Assert-Equal $installedModule.digest_sha256 $digestSha256 "marketplace custom module digest mismatch"
  Assert-True ([bool]$installedModule.verified) "marketplace custom module verified should be true"
  Assert-Equal $installedModule.verification_mode "hmac-sha256" "marketplace custom module verification_mode mismatch"

  $executeAllow = Invoke-Rpc -Method "edge.wasm.execute" -Id "fs5-wasm-exec-allow" -Params @{
    moduleId = $moduleId
    hostHooks = @("fs.read")
    input = "run"
  }
  $executeAllowResult = $executeAllow.Json.result
  Assert-True ($null -ne $executeAllowResult) "edge.wasm.execute allow result missing (raw response: $($executeAllow.Content))"
  Assert-Equal $executeAllowResult.status "completed" "edge.wasm.execute allow status mismatch"
  Assert-Equal $executeAllowResult.hostHooks "fs.read" "edge.wasm.execute allow hostHooks mismatch"
  Assert-Equal $executeAllowResult.output "custom-module:$moduleId executed" "edge.wasm.execute allow output mismatch"
  Assert-True ([bool]$executeAllowResult.trust.verified) "edge.wasm.execute allow trust.verified should be true"
  Assert-Equal $executeAllowResult.trust.verificationMode "hmac-sha256" "edge.wasm.execute allow verificationMode mismatch"
  Assert-Equal $executeAllowResult.trust.sha256 $digestSha256 "edge.wasm.execute allow trust.sha256 mismatch"

  $executeDeny = Invoke-Rpc -Method "edge.wasm.execute" -Id "fs5-wasm-exec-deny" -Params @{
    moduleId = $moduleId
    hostHooks = @("network.fetch")
  }
  Assert-True ($null -ne $executeDeny.Json.error) "edge.wasm.execute deny error missing"
  Assert-Equal $executeDeny.Json.error.code -32043 "edge.wasm.execute deny code mismatch"
  Assert-Contains $executeDeny.Json.error.message "network.fetch" "edge.wasm.execute deny message mismatch"

  $badInstall = Invoke-Rpc -Method "edge.wasm.install" -Id "fs5-wasm-bad-install" -Params @{
    moduleId = $badModuleId
    version = $version
    description = $description
    capabilities = $capabilities
    sourceUrl = $sourceUrl
    sha256 = $badDigestSha256
    signature = $signature
    signer = $signer
    requireSignature = $true
    trustPolicy = "signature"
  }
  Assert-True ($null -ne $badInstall.Json.error) "bad-signature install error missing"
  Assert-Equal $badInstall.Json.error.code -32042 "bad-signature install code mismatch"
  Assert-Contains $badInstall.Json.error.message "signature verification failed" "bad-signature install message mismatch"

  $remove = Invoke-Rpc -Method "edge.wasm.remove" -Id "fs5-wasm-remove" -Params @{
    moduleId = $moduleId
  }
  $removeResult = $remove.Json.result
  Assert-True ($null -ne $removeResult) "edge.wasm.remove result missing"
  Assert-Equal $removeResult.status "removed" "edge.wasm.remove status mismatch"
  Assert-True ([bool]$removeResult.removed) "edge.wasm.remove removed should be true"
  Assert-Equal $removeResult.customModuleCount 0 "edge.wasm.remove customModuleCount mismatch"

  $executeMissing = Invoke-Rpc -Method "edge.wasm.execute" -Id "fs5-wasm-exec-missing" -Params @{
    moduleId = $moduleId
    hostHooks = @("fs.read")
  }
  Assert-True ($null -ne $executeMissing.Json.error) "post-remove execute error missing"
  Assert-Equal $executeMissing.Json.error.code -32004 "post-remove execute code mismatch"
  Assert-Contains $executeMissing.Json.error.message "wasm module not found" "post-remove execute message mismatch"

  Write-Output "EDGE_WASM_HTTP=200"
  Write-Output "EDGE_WASM_LIST_INITIAL_CUSTOMS=$($list1Result.customModuleCount)"
  Write-Output "EDGE_WASM_INSTALL_MODE=$($installResult.module.verificationMode)"
  Write-Output "EDGE_WASM_INSTALL_VERIFIED=$($installResult.module.verified)"
  Write-Output "EDGE_WASM_POST_INSTALL_CUSTOMS=$($list2Result.customModuleCount)"
  Write-Output "EDGE_WASM_EXEC_ALLOW_STATUS=$($executeAllowResult.status)"
  Write-Output "EDGE_WASM_EXEC_ALLOW_OUTPUT=$($executeAllowResult.output)"
  Write-Output "EDGE_WASM_EXEC_DENY_CODE=$($executeDeny.Json.error.code)"
  Write-Output "EDGE_WASM_BAD_SIG_CODE=$($badInstall.Json.error.code)"
  Write-Output "EDGE_WASM_REMOVE_STATUS=$($removeResult.status)"
  Write-Output "EDGE_WASM_POST_REMOVE_CODE=$($executeMissing.Json.error.code)"
}
finally {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
  Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
  if (Test-Path $stateDir) {
    Remove-Item $stateDir -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_WASM_TRUST_KEY -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_WASM_TRUST_POLICY -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_STATE_PATH -ErrorAction SilentlyContinue
}
