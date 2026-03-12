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

$port = 8094
$mockPort = Resolve-FreeTcpPort
$env:OPENCLAW_ZIG_HTTP_PORT = "$port"

$stdoutLog = Join-Path $repo "tmp_smoke_browser_completion_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_browser_completion_stderr.log"
$mockStdoutLog = Join-Path $repo "tmp_smoke_browser_completion_mock_stdout.log"
$mockStderrLog = Join-Path $repo "tmp_smoke_browser_completion_mock_stderr.log"
$mockCapture = Join-Path $repo "tmp_smoke_browser_completion_mock.jsonl"
$mockReady = Join-Path $repo "tmp_smoke_browser_completion_mock.ready"
$mockScript = Join-Path $repo "tmp_smoke_browser_completion_mock.ps1"
Remove-Item $stdoutLog,$stderrLog,$mockStdoutLog,$mockStderrLog,$mockCapture,$mockReady,$mockScript -ErrorAction SilentlyContinue

@'
param(
  [int]$Port,
  [string]$CapturePath,
  [string]$ReadyPath
)

$ErrorActionPreference = "Stop"

function Read-ExactChars {
  param(
    [System.IO.StreamReader]$Reader,
    [int]$Count
  )
  if ($Count -le 0) { return "" }
  $buffer = New-Object char[] $Count
  $read = 0
  while ($read -lt $Count) {
    $chunk = $Reader.Read($buffer, $read, $Count - $read)
    if ($chunk -le 0) { break }
    $read += $chunk
  }
  if ($read -le 0) { return "" }
  return (-join $buffer[0..($read - 1)])
}

function Write-JsonResponse {
  param(
    [System.Net.Sockets.TcpClient]$Client,
    [int]$StatusCode,
    [string]$StatusText,
    [string]$Body
  )
  $stream = $Client.GetStream()
  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $header = "HTTP/1.1 $StatusCode $StatusText`r`nContent-Type: application/json`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  $stream.Write($bodyBytes, 0, $bodyBytes.Length)
  $stream.Flush()
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Set-Content -Path $ReadyPath -Value "ready" -NoNewline

try {
  $handledCompletion = $false
  while (-not $handledCompletion) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
      try {
        $requestLine = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($requestLine)) {
          Write-JsonResponse -Client $client -StatusCode 400 -StatusText "Bad Request" -Body '{"error":"empty request"}'
          continue
        }

        $headerMap = @{}
        while ($true) {
          $line = $reader.ReadLine()
          if ($null -eq $line -or $line.Length -eq 0) { break }
          $separator = $line.IndexOf(':')
          if ($separator -gt 0) {
            $name = $line.Substring(0, $separator).Trim().ToLowerInvariant()
            $value = $line.Substring($separator + 1).Trim()
            $headerMap[$name] = $value
          }
        }

        $contentLength = 0
        if ($headerMap.ContainsKey("content-length")) {
          [void][int]::TryParse($headerMap["content-length"], [ref]$contentLength)
        }
        $body = Read-ExactChars -Reader $reader -Count $contentLength

        $parts = $requestLine.Split(' ')
        $method = if ($parts.Length -ge 1) { $parts[0] } else { "" }
        $path = if ($parts.Length -ge 2) { $parts[1] } else { "/" }
        @{
          method = $method
          path = $path
          body = $body
        } | ConvertTo-Json -Compress | Add-Content -Path $CapturePath

        if ($method -eq "GET" -and $path -eq "/json/version") {
          Write-JsonResponse -Client $client -StatusCode 200 -StatusText "OK" -Body '{"Browser":"OpenClaw FS2 Mock","Protocol-Version":"1.3"}'
          continue
        }

        if ($method -eq "POST" -and $path -eq "/v1/chat/completions") {
          Write-JsonResponse -Client $client -StatusCode 200 -StatusText "OK" -Body '{"model":"gpt-5.2","output_text":"mock browser completion from zig"}'
          $handledCompletion = $true
          continue
        }

        Write-JsonResponse -Client $client -StatusCode 404 -StatusText "Not Found" -Body '{"error":"not found"}'
      }
      finally {
        $reader.Dispose()
      }
    }
    finally {
      $client.Close()
    }
  }
}
finally {
  $listener.Stop()
}
'@ | Set-Content -Path $mockScript -NoNewline

$shellExe = (Get-Process -Id $PID).Path
$mockArgumentList = @("-NoProfile", "-File", $mockScript, "-Port", "$mockPort", "-CapturePath", $mockCapture, "-ReadyPath", $mockReady)
if ($isWindowsHost) {
  $mockArgumentList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $mockScript, "-Port", "$mockPort", "-CapturePath", $mockCapture, "-ReadyPath", $mockReady)
}
$mockStartProcessParams = @{
  FilePath = $shellExe
  ArgumentList = $mockArgumentList
  WorkingDirectory = $repo
  PassThru = $true
  RedirectStandardOutput = $mockStdoutLog
  RedirectStandardError = $mockStderrLog
}
if ($isWindowsHost) {
  $mockStartProcessParams.WindowStyle = "Hidden"
}
$mockProc = Start-Process @mockStartProcessParams

$mockReadyOk = $false
for ($i = 0; $i -lt 40; $i++) {
  if ($mockProc.HasExited) {
    break
  }
  if (Test-Path $mockReady) {
    $mockReadyOk = $true
    break
  }
  Start-Sleep -Milliseconds 250
}
if (-not $mockReadyOk) {
  $stderrTail = if (Test-Path $mockStderrLog) { (Get-Content $mockStderrLog -Tail 120 -ErrorAction SilentlyContinue) -join "`n" } else { "" }
  $stdoutTail = if (Test-Path $mockStdoutLog) { (Get-Content $mockStdoutLog -Tail 60 -ErrorAction SilentlyContinue) -join "`n" } else { "" }
  $exitCode = if ($mockProc.HasExited) { $mockProc.ExitCode } else { "running" }
  throw "mock browser bridge did not become ready on port $mockPort (exit=$exitCode)`nSTDERR:`n$stderrTail`nSTDOUT:`n$stdoutTail"
}

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
  $payload = @{
    id = "browser-success"
    method = "browser.request"
    params = @{
      provider = "chatgpt"
      endpoint = "http://127.0.0.1:$mockPort"
      prompt = "hello from browser completion smoke"
      sessionId = "fs2-browser-success"
      includeMemoryContext = $false
    }
  } | ConvertTo-Json -Depth 8 -Compress

  $result = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $payload -UseBasicParsing
  $resultJson = $result.Content | ConvertFrom-Json
  if ($result.StatusCode -ne 200) {
    throw "browser.request did not return HTTP 200"
  }
  if (-not $resultJson.result) {
    throw "browser.request result payload missing"
  }

  $rpcResult = $resultJson.result
  if (-not $rpcResult.ok) { throw "browser.request result.ok is false" }
  if ($rpcResult.status -ne "completed") { throw "browser.request status is not completed" }
  if ($rpcResult.executionPath -ne "lightpanda-bridge") { throw "browser.request executionPath is not lightpanda-bridge" }
  if ($rpcResult.directProvider) { throw "browser.request directProvider should be false" }
  if (-not $rpcResult.probe.ok) { throw "browser.request probe.ok is false" }
  if (-not $rpcResult.bridgeCompletion.requested) { throw "bridgeCompletion.requested is false" }
  if (-not $rpcResult.bridgeCompletion.ok) { throw "bridgeCompletion.ok is false" }
  if ($rpcResult.bridgeCompletion.assistantText -ne "mock browser completion from zig") {
    throw "unexpected assistant text from browser completion success proof"
  }
  if ($rpcResult.bridgeCompletion.requestUrl -ne "http://127.0.0.1:$mockPort/v1/chat/completions") {
    throw "unexpected bridge completion requestUrl"
  }

  for ($i = 0; $i -lt 40; $i++) {
    if (Test-Path $mockCapture) {
      $lineCount = (Get-Content $mockCapture -ErrorAction SilentlyContinue).Count
      if ($lineCount -ge 2) { break }
    }
    Start-Sleep -Milliseconds 250
  }
  if (-not (Test-Path $mockCapture)) {
    throw "mock capture file missing"
  }
  $captureLines = Get-Content $mockCapture | Where-Object { $_.Trim().Length -gt 0 }
  if ($captureLines.Count -lt 2) {
    throw "mock bridge did not record both probe and completion requests"
  }
  $captures = @($captureLines | ForEach-Object { $_ | ConvertFrom-Json })
  $probeCapture = $captures | Where-Object { $_.method -eq "GET" -and $_.path -eq "/json/version" } | Select-Object -First 1
  $completionCapture = $captures | Where-Object { $_.method -eq "POST" -and $_.path -eq "/v1/chat/completions" } | Select-Object -First 1
  if ($null -eq $probeCapture) { throw "missing GET /json/version capture" }
  if ($null -eq $completionCapture) { throw "missing POST /v1/chat/completions capture" }

  $completionBody = $completionCapture.body | ConvertFrom-Json
  if ($completionBody.provider -ne "chatgpt") { throw "mock completion payload provider mismatch" }
  if ($completionBody.model -ne "gpt-5.2") { throw "mock completion payload model mismatch" }
  if ($completionBody.messages.Count -lt 1) { throw "mock completion payload messages missing" }
  if ($completionBody.messages[0].role -ne "user") { throw "mock completion payload first role mismatch" }
  if ($completionBody.messages[0].content -notmatch "hello from browser completion smoke") { throw "mock completion payload prompt mismatch" }

  Write-Output "BROWSER_REQUEST_SUCCESS_HTTP=$($result.StatusCode)"
  Write-Output "BROWSER_REQUEST_SUCCESS_STATUS=$($rpcResult.status)"
  Write-Output "BROWSER_REQUEST_SUCCESS_EXECUTION_PATH=$($rpcResult.executionPath)"
  Write-Output "BROWSER_REQUEST_SUCCESS_PROBE_OK=$($rpcResult.probe.ok)"
  Write-Output "BROWSER_REQUEST_SUCCESS_COMPLETION_OK=$($rpcResult.bridgeCompletion.ok)"
  Write-Output "BROWSER_REQUEST_SUCCESS_ASSISTANT_TEXT=$($rpcResult.bridgeCompletion.assistantText)"
  Write-Output "BROWSER_REQUEST_SUCCESS_CAPTURE_COUNT=$($captures.Count)"
  Write-Output "BROWSER_REQUEST_SUCCESS_CAPTURE_PROVIDER=$($completionBody.provider)"
  Write-Output "BROWSER_REQUEST_SUCCESS_CAPTURE_MODEL=$($completionBody.model)"
}
finally {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
  if ($null -ne $mockProc -and -not $mockProc.HasExited) {
    Stop-Process -Id $mockProc.Id -Force
  }
  Remove-Item $stdoutLog,$stderrLog,$mockStdoutLog,$mockStderrLog,$mockCapture,$mockReady,$mockScript -ErrorAction SilentlyContinue
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
}
