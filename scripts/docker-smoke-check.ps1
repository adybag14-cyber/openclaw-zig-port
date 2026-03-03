$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$defaultZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
$zig = if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) { $env:OPENCLAW_ZIG_BIN } else { $defaultZig }
if (-not (Test-Path $zig)) {
  throw "Zig binary not found at '$zig'. Set OPENCLAW_ZIG_BIN to a valid zig executable path."
}
$port = 8091
$env:OPENCLAW_ZIG_HTTP_PORT = "$port"
$proc = Start-Process -FilePath $zig -ArgumentList @("build","run","--","--serve") -WorkingDirectory $repo -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 5
try {
  $health = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing
  $rpcBody = '{"id":"dock-smoke","method":"status","params":{}}'
  $rpc = Invoke-WebRequest -Uri "http://127.0.0.1:$port/rpc" -Method Post -ContentType "application/json" -Body $rpcBody -UseBasicParsing

  $dockerHealthCode = docker run --rm curlimages/curl:8.12.1 -s -o /dev/null -w "%{http_code}" "http://host.docker.internal:$port/health"
  $dockerRpcCode = docker run --rm curlimages/curl:8.12.1 -s -o /dev/null -w "%{http_code}" -H "Content-Type: application/json" -d $rpcBody "http://host.docker.internal:$port/rpc"

  Write-Output "HOST_HEALTH_HTTP=$($health.StatusCode)"
  Write-Output "HOST_RPC_HTTP=$($rpc.StatusCode)"
  Write-Output "HOST_RPC_BODY=$($rpc.Content)"
  Write-Output "DOCKER_HEALTH_HTTP=$dockerHealthCode"
  Write-Output "DOCKER_RPC_HTTP=$dockerRpcCode"
}
finally {
  if ($null -ne $proc -and -not $proc.HasExited) {
    Stop-Process -Id $proc.Id -Force
  }
  Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
}
