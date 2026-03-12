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

$port = 8093
$env:OPENCLAW_ZIG_HTTP_PORT = "$port"
$stdoutLog = Join-Path $repo "tmp_smoke_telegram_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_telegram_stderr.log"
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

  $linkPayload = @{
    id = "tg-auth-link"
    method = "send"
    params = @{
      channel = "telegram"
      to = "smoke-room"
      sessionId = "smoke-session"
      message = "/auth link chatgpt"
    }
  } | ConvertTo-Json -Depth 8 -Compress
  $link = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $linkPayload -UseBasicParsing
  $linkJson = $link.Content | ConvertFrom-Json
  $linkReply = "$($linkJson.result.reply)"
  if ([string]::IsNullOrWhiteSpace($linkReply)) {
    throw "/auth link response is empty"
  }
  if ($linkReply -notmatch "Auth URL: ") {
    throw "/auth link reply does not include auth URL"
  }
  if ($linkReply -notmatch [regex]::Escape($loginCode)) {
    throw "/auth link reply does not include login code"
  }
  if ($linkReply -match "Session:") {
    throw "/auth link reply still exposes legacy session text"
  }
  if ($linkReply -match "Status:") {
    throw "/auth link reply still exposes legacy status text"
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
  Write-Output "TELEGRAM_SEND_AUTH_LINK_HTTP=$($link.StatusCode)"
  Write-Output "TELEGRAM_SEND_AUTH_COMPLETE_HTTP=$($complete.StatusCode)"
  Write-Output "TELEGRAM_SEND_CHAT_HTTP=$($chat.StatusCode)"
  Write-Output "TELEGRAM_POLL_HTTP=$($poll.StatusCode)"
  Write-Output "TELEGRAM_AUTH_LINK_HAS_URL=$([bool]($linkReply -match 'Auth URL: '))"
  Write-Output "TELEGRAM_AUTH_LINK_HAS_CODE=$([bool]($linkReply -match [regex]::Escape($loginCode)))"
  Write-Output "TELEGRAM_AUTH_LINK_HAS_SESSION_TEXT=$([bool]($linkReply -match 'Session:'))"
  Write-Output "TELEGRAM_AUTH_COMPLETE_STATUS=$($completeJson.result.authStatus)"
  Write-Output "TELEGRAM_CHAT_REPLY_HAS_OPENCLAW=$([bool]($chatJson.result.reply -match 'OpenClaw Zig'))"
  Write-Output "TELEGRAM_POLL_COUNT=$($pollJson.result.count)"
}
finally {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
  Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
}
