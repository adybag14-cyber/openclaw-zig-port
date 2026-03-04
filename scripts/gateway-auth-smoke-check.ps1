param(
    [int] $Port = 8097,
    [int] $ReadyAttempts = 80,
    [int] $ReadySleepMs = 500,
    [string] $AuthToken = "zig-smoke-token",
    [switch] $SkipBuild,
    [switch] $KeepLogs
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Resolve-ZigExecutable {
    $defaultWindowsZig = "C:\Users\Ady\Documents\toolchains\zig-master\current\zig.exe"
    if ($env:OPENCLAW_ZIG_BIN -and $env:OPENCLAW_ZIG_BIN.Trim().Length -gt 0) {
        if (-not (Test-Path $env:OPENCLAW_ZIG_BIN)) {
            throw "OPENCLAW_ZIG_BIN is set but not found: $($env:OPENCLAW_ZIG_BIN)"
        }
        return $env:OPENCLAW_ZIG_BIN
    }

    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($null -ne $zigCmd -and $zigCmd.Path) {
        return $zigCmd.Path
    }

    if (Test-Path $defaultWindowsZig) {
        return $defaultWindowsZig
    }

    throw "Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure zig is on PATH."
}

function Resolve-AgentExecutable {
    param([string] $RepoPath)

    $candidates = @(
        (Join-Path $RepoPath "zig-out\bin\openclaw-zig.exe"),
        (Join-Path $RepoPath "zig-out/bin/openclaw-zig.exe"),
        (Join-Path $RepoPath "zig-out\bin\openclaw-zig"),
        (Join-Path $RepoPath "zig-out/bin/openclaw-zig")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) {
            return (Resolve-Path $candidate).Path
        }
    }

    throw "openclaw-zig executable not found under zig-out/bin."
}

function Invoke-Rpc {
    param(
        [string] $Url,
        [string] $Id,
        [string] $Method,
        [hashtable] $Params,
        [hashtable] $Headers
    )

    $payload = @{
        id = $Id
        method = $Method
        params = if ($null -eq $Params) { @{} } else { $Params }
    } | ConvertTo-Json -Depth 10 -Compress

    $req = @{
        Uri = $Url
        Method = "Post"
        ContentType = "application/json"
        Body = $payload
        UseBasicParsing = $true
    }
    if ($null -ne $Headers) {
        $req.Headers = $Headers
    }
    return Invoke-WebRequest @req
}

function Connect-WebSocket {
    param(
        [Uri] $Uri,
        [string] $BearerToken
    )

    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    if (-not [string]::IsNullOrWhiteSpace($BearerToken)) {
        $ws.Options.SetRequestHeader("Authorization", "Bearer $BearerToken")
    }
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(15))
    $null = $ws.ConnectAsync($Uri, $cts.Token).GetAwaiter().GetResult()
    return $ws
}

$zig = Resolve-ZigExecutable
if (-not $SkipBuild) {
    & $zig build --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE"
    }
}

$exe = Resolve-AgentExecutable -RepoPath $repo
$baseUrl = "http://127.0.0.1:$Port"
$wsUri = [Uri]::new("ws://127.0.0.1:$Port/ws")
$rpcUrl = "$baseUrl/rpc"

$env:OPENCLAW_ZIG_HTTP_PORT = "$Port"
$env:OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN = "true"
$env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN = $AuthToken
$env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_ENABLED = "true"
$env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_WINDOW_MS = "60000"
$env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_MAX_REQUESTS = "200"

$stdoutLog = Join-Path $repo "tmp_smoke_gateway_auth_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_gateway_auth_stderr.log"
Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath $exe -ArgumentList @("--serve") -WorkingDirectory $repo -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog

$ready = $false
for ($i = 0; $i -lt $ReadyAttempts; $i++) {
    if ($proc.HasExited) { break }
    try {
        $health = Invoke-WebRequest -Uri "$baseUrl/health" -UseBasicParsing -TimeoutSec 2
        if ($health.StatusCode -eq 200) {
            $ready = $true
            break
        }
    } catch {
        Start-Sleep -Milliseconds $ReadySleepMs
    }
}

if (-not $ready) {
    $stderrTail = if (Test-Path $stderrLog) { (Get-Content $stderrLog -Tail 120 -ErrorAction SilentlyContinue) -join "`n" } else { "" }
    $stdoutTail = if (Test-Path $stdoutLog) { (Get-Content $stdoutLog -Tail 80 -ErrorAction SilentlyContinue) -join "`n" } else { "" }
    $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { "running" }
    throw "openclaw-zig did not become ready on $baseUrl (exit=$exitCode)`nSTDERR:`n$stderrTail`nSTDOUT:`n$stdoutTail"
}

try {
    # RPC should fail without Authorization header.
    $rpcUnauthorized = $false
    try {
        $unauthResp = Invoke-Rpc -Url $rpcUrl -Id "auth-smoke-unauth" -Method "status" -Params @{} -Headers $null
        if ($unauthResp.StatusCode -eq 401) {
            $rpcUnauthorized = $true
        }
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 401) {
            $rpcUnauthorized = $true
        } else {
            throw
        }
    }
    if (-not $rpcUnauthorized) {
        throw "expected unauthorized /rpc request to return 401"
    }

    # RPC should pass with Authorization header.
    $authResp = Invoke-Rpc -Url $rpcUrl -Id "auth-smoke-ok" -Method "status" -Params @{} -Headers @{ Authorization = "Bearer $AuthToken" }
    if ($authResp.StatusCode -ne 200) {
        throw "expected authorized /rpc status=200, got $($authResp.StatusCode)"
    }
    $authJson = $authResp.Content | ConvertFrom-Json
    if ($null -eq $authJson.result) {
        throw "authorized /rpc response missing result payload"
    }

    # WebSocket should fail without Authorization header.
    $wsUnauthorized = $false
    try {
        $wsNoAuth = Connect-WebSocket -Uri $wsUri -BearerToken ""
        $wsNoAuth.Dispose()
    } catch {
        if ($_.Exception.Message -match "401" -or $_.Exception.Message -match "Unauthorized") {
            $wsUnauthorized = $true
        } elseif ($_.Exception.InnerException -and $_.Exception.InnerException.Message -match "401") {
            $wsUnauthorized = $true
        } else {
            throw
        }
    }
    if (-not $wsUnauthorized) {
        throw "expected websocket upgrade without token to fail with unauthorized response"
    }

    # WebSocket should pass with Authorization header.
    $ws = Connect-WebSocket -Uri $wsUri -BearerToken $AuthToken
    $frame = '{"id":"auth-ws-1","method":"status","params":{}}'
    $frameBytes = [System.Text.Encoding]::UTF8.GetBytes($frame)
    $frameSegment = [ArraySegment[byte]]::new($frameBytes)
    $null = $ws.SendAsync($frameSegment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

    $buffer = New-Object byte[] 16384
    $builder = [System.Text.StringBuilder]::new()
    do {
        $segment = [ArraySegment[byte]]::new($buffer)
        $receive = $ws.ReceiveAsync($segment, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        if ($receive.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            throw "authorized websocket closed before rpc response"
        }
        $chunk = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $receive.Count)
        [void]$builder.Append($chunk)
    } while (-not $receive.EndOfMessage)

    $wsJson = $builder.ToString() | ConvertFrom-Json
    if ($null -eq $wsJson.result) {
        throw "authorized websocket response missing result payload"
    }

    Write-Output "GATEWAY_AUTH_RPC_UNAUTHORIZED=ok"
    Write-Output "GATEWAY_AUTH_RPC_AUTHORIZED=ok"
    Write-Output "GATEWAY_AUTH_WS_UNAUTHORIZED=ok"
    Write-Output "GATEWAY_AUTH_WS_AUTHORIZED=ok"

    try {
        $null = $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "auth-smoke-complete", [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
    } catch {
        # Server-side close without full handshake is acceptable for this smoke.
    }
}
finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }
    Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_ENABLED -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_WINDOW_MS -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_MAX_REQUESTS -ErrorAction SilentlyContinue
    if (-not $KeepLogs) {
        Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
    }
}
