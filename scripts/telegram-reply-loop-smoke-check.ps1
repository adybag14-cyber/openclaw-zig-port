$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$defaultZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
$zig = if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) { $env:OPENCLAW_ZIG_BIN } else { $defaultZig }
if (-not (Test-Path $zig)) {
  throw "Zig binary not found at '$zig'. Set OPENCLAW_ZIG_BIN to a valid zig executable path."
}

$port = 8093
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
  $startPayload = @{
    id = "tg-auth-start"
    method = "send"
    params = @{
      channel = "telegram"
      to = "smoke-room"
      sessionId = "smoke-session"
      message = "/auth start chatgpt"
    }
  } | ConvertTo-Json -Depth 8 -Compress
  $start = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $startPayload -UseBasicParsing
  $startJson = $start.Content | ConvertFrom-Json
  $loginSessionId = "$($startJson.result.loginSessionId)"
  $loginCode = "$($startJson.result.loginCode)"
  if ([string]::IsNullOrWhiteSpace($loginSessionId) -or [string]::IsNullOrWhiteSpace($loginCode)) {
    throw "missing auth session id or code from /auth start send response"
  }

  $completePayload = @{
    id = "tg-auth-complete"
    method = "send"
    params = @{
      channel = "telegram"
      to = "smoke-room"
      sessionId = "smoke-session"
      message = "/auth complete chatgpt $loginCode $loginSessionId"
    }
  } | ConvertTo-Json -Depth 8 -Compress
  $complete = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $completePayload -UseBasicParsing
  $completeJson = $complete.Content | ConvertFrom-Json

  $chatPayload = @{
    id = "tg-chat"
    method = "send"
    params = @{
      channel = "telegram"
      to = "smoke-room"
      sessionId = "smoke-session"
      message = "hello from telegram smoke"
    }
  } | ConvertTo-Json -Depth 8 -Compress
  $chat = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $chatPayload -UseBasicParsing
  $chatJson = $chat.Content | ConvertFrom-Json

  $pollPayload = @{
    id = "tg-poll"
    method = "poll"
    params = @{
      channel = "telegram"
      limit = 10
    }
  } | ConvertTo-Json -Depth 8 -Compress
  $poll = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $pollPayload -UseBasicParsing
  $pollJson = $poll.Content | ConvertFrom-Json

  if (-not $pollJson.result -or $pollJson.result.count -lt 1) {
    throw "poll did not return queued updates"
  }

  Write-Output "TELEGRAM_SEND_AUTH_START_HTTP=$($start.StatusCode)"
  Write-Output "TELEGRAM_SEND_AUTH_COMPLETE_HTTP=$($complete.StatusCode)"
  Write-Output "TELEGRAM_SEND_CHAT_HTTP=$($chat.StatusCode)"
  Write-Output "TELEGRAM_POLL_HTTP=$($poll.StatusCode)"
  Write-Output "TELEGRAM_AUTH_COMPLETE_STATUS=$($completeJson.result.authStatus)"
  Write-Output "TELEGRAM_CHAT_REPLY_HAS_OPENCLAW=$([bool]($chatJson.result.reply -match 'OpenClaw Zig'))"
  Write-Output "TELEGRAM_POLL_COUNT=$($pollJson.result.count)"
}
finally {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
}
