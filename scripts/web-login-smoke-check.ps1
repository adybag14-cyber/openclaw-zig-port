$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$defaultZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
$zig = if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) { $env:OPENCLAW_ZIG_BIN } else { $defaultZig }
if (-not (Test-Path $zig)) {
  throw "Zig binary not found at '$zig'. Set OPENCLAW_ZIG_BIN to a valid zig executable path."
}

$port = 8092
$env:OPENCLAW_ZIG_HTTP_PORT = "$port"
$proc = Start-Process -FilePath $zig -ArgumentList @("build","run","--","--serve") -WorkingDirectory $repo -PassThru -WindowStyle Hidden

$ready = $false
for ($i = 0; $i -lt 30; $i++) {
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
  throw "openclaw-zig server did not become ready on port $port"
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
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
}
