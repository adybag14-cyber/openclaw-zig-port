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

$port = 8092
$env:OPENCLAW_ZIG_HTTP_PORT = "$port"
$stdoutLog = Join-Path $repo "tmp_smoke_weblogin_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_weblogin_stderr.log"
Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
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
  if ($proc.HasExited) {
    break
  }
  try {
    $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
    if ($health.StatusCode -eq 200) {
      $ready = $true
      break
    }
  } catch {
    Start-Sleep -Milliseconds 500
  }
}
if (-not $ready) {
  $stderrTail = if (Test-Path $stderrLog) { (Get-Content $stderrLog -Tail 120 -ErrorAction SilentlyContinue) -join "`n" } else { "" }
  $stdoutTail = if (Test-Path $stdoutLog) { (Get-Content $stdoutLog -Tail 60 -ErrorAction SilentlyContinue) -join "`n" } else { "" }
  $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { "running" }
  throw "openclaw-zig server did not become ready on port $port (exit=$exitCode)`nSTDERR:`n$stderrTail`nSTDOUT:`n$stdoutTail"
}

try {
  $startBody = '{"id":"wl-start","method":"web.login.start","params":{"provider":"chatgpt","model":"gpt-5.2"}}'
  $start = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $startBody -UseBasicParsing
  $startJson = $start.Content | ConvertFrom-Json
  $login = $startJson.result.login
  if (-not $login.loginSessionId) { throw "missing loginSessionId in start response" }
  if (-not $login.code) { throw "missing code in start response" }

  $waitPayload = @{
    id = "wl-wait"
    method = "web.login.wait"
    params = @{
      loginSessionId = $login.loginSessionId
      timeoutMs = 20
    }
  } | ConvertTo-Json -Depth 6 -Compress
  $wait = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $waitPayload -UseBasicParsing
  $waitJson = $wait.Content | ConvertFrom-Json

  $completePayload = @{
    id = "wl-complete"
    method = "web.login.complete"
    params = @{
      loginSessionId = $login.loginSessionId
      code = $login.code
    }
  } | ConvertTo-Json -Depth 6 -Compress
  $complete = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $completePayload -UseBasicParsing
  $completeJson = $complete.Content | ConvertFrom-Json

  $statusPayload = @{
    id = "wl-status"
    method = "web.login.status"
    params = @{
      loginSessionId = $login.loginSessionId
    }
  } | ConvertTo-Json -Depth 6 -Compress
  $status = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $statusPayload -UseBasicParsing
  $statusJson = $status.Content | ConvertFrom-Json

  Write-Output "WEB_LOGIN_START_HTTP=$($start.StatusCode)"
  Write-Output "WEB_LOGIN_WAIT_HTTP=$($wait.StatusCode)"
  Write-Output "WEB_LOGIN_COMPLETE_HTTP=$($complete.StatusCode)"
  Write-Output "WEB_LOGIN_STATUS_HTTP=$($status.StatusCode)"
  Write-Output "WEB_LOGIN_WAIT_STATUS=$($waitJson.result.status)"
  Write-Output "WEB_LOGIN_COMPLETE_STATUS=$($completeJson.result.status)"
  Write-Output "WEB_LOGIN_STATUS_STATUS=$($statusJson.result.status)"
}
finally {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
  Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
}
