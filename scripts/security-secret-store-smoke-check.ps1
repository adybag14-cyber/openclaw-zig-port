param(
    [int] $Port = 8098,
    [int] $ReadyAttempts = 80,
    [int] $ReadySleepMs = 500,
    [string] $AuthToken = "zig-security-smoke-token",
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

function Wait-HttpReady {
    param(
        [string] $Url,
        [int] $Attempts,
        [int] $SleepMs
    )

    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 2
            if ($response.StatusCode -eq 200) {
                return
            }
        } catch {
            Start-Sleep -Milliseconds $SleepMs
        }
    }

    throw "endpoint did not become ready: $Url"
}

function Invoke-Rpc {
    param(
        [string] $Url,
        [string] $Id,
        [string] $Method,
        [hashtable] $Params,
        [string] $BearerToken
    )

    $payload = @{
        id = $Id
        method = $Method
        params = if ($null -eq $Params) { @{} } else { $Params }
    } | ConvertTo-Json -Depth 12 -Compress

    $response = Invoke-WebRequest -Uri $Url -Method Post -ContentType "application/json" -Headers @{ Authorization = "Bearer $BearerToken" } -Body $payload -UseBasicParsing
    $json = $response.Content | ConvertFrom-Json
    if ($null -ne $json.error) {
        throw "RPC $Method returned error: $($json.error | ConvertTo-Json -Depth 8 -Compress)"
    }
    return @{
        StatusCode = $response.StatusCode
        Json = $json
        Content = $response.Content
    }
}

function Find-DoctorCheck {
    param(
        [object[]] $Checks,
        [string] $Id
    )

    foreach ($check in $Checks) {
        if ("$($check.id)" -eq $Id) {
            return $check
        }
    }
    throw "doctor check '$Id' not found"
}

function Start-Server {
    param(
        [string] $Executable,
        [string] $WorkingDirectory,
        [string] $StdoutLog,
        [string] $StderrLog
    )

    $proc = Start-Process -FilePath $Executable -ArgumentList @("--serve") -WorkingDirectory $WorkingDirectory -PassThru -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog
    Wait-HttpReady -Url "http://127.0.0.1:$Port/health" -Attempts $ReadyAttempts -SleepMs $ReadySleepMs
    return $proc
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
$rpcUrl = "$baseUrl/rpc"
$stdoutLog = Join-Path $repo "tmp_smoke_security_secret_store_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_security_secret_store_stderr.log"
$tempRoot = Join-Path $repo "tmp_fs4_security_secret_store"
$storeFile = Join-Path $tempRoot "secrets.store.enc.json"
$policyFile = Join-Path $tempRoot "policy.json"
$stateDir = Join-Path $tempRoot "state"
Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $tempRoot | Out-Null
New-Item -ItemType Directory -Path $stateDir | Out-Null
'{"rules":[]}' | Set-Content -Path $policyFile -NoNewline

$env:OPENCLAW_ZIG_HTTP_PORT = "$Port"
$env:OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN = "true"
$env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN = $AuthToken
$env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_ENABLED = "true"
$env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_WINDOW_MS = "60000"
$env:OPENCLAW_ZIG_GATEWAY_RATE_LIMIT_MAX_REQUESTS = "300"
$env:OPENCLAW_ZIG_SECRET_BACKEND = "encrypted-file"
$env:OPENCLAW_ZIG_SECRET_STORE_PATH = $storeFile
$env:OPENCLAW_ZIG_SECRET_STORE_KEY = "0123456789abcdef0123456789abcdef"
$env:OPENCLAW_ZIG_STATE_PATH = $stateDir
$env:OPENCLAW_ZIG_SECURITY_POLICY_BUNDLE_PATH = $policyFile

$proc = $null

try {
    $proc = Start-Server -Executable $exe -WorkingDirectory $repo -StdoutLog $stdoutLog -StderrLog $stderrLog

    $doctor = Invoke-Rpc -Url $rpcUrl -Id "security-doctor" -Method "doctor" -Params @{} -BearerToken $AuthToken
    $audit = Invoke-Rpc -Url $rpcUrl -Id "security-audit" -Method "security.audit" -Params @{} -BearerToken $AuthToken
    $statusBefore = Invoke-Rpc -Url $rpcUrl -Id "security-store-status-before" -Method "secrets.store.status" -Params @{} -BearerToken $AuthToken

    $doctorResult = $doctor.Json.result
    $auditResult = $audit.Json.result
    $statusBeforeResult = $statusBefore.Json.result
    $gatewayAuthCheck = Find-DoctorCheck -Checks $doctorResult.checks -Id "gateway.auth_token"
    $gatewayRateLimitCheck = Find-DoctorCheck -Checks $doctorResult.checks -Id "gateway.rate_limit"
    $runtimeStateCheck = Find-DoctorCheck -Checks $doctorResult.checks -Id "runtime.state_path"
    $policyBundleCheck = Find-DoctorCheck -Checks $doctorResult.checks -Id "security.policy_bundle"

    if ($doctor.StatusCode -ne 200) { throw "doctor did not return HTTP 200" }
    if ("$($gatewayAuthCheck.status)" -ne "pass" -or "$($gatewayAuthCheck.message)" -ne "configured") {
        throw "gateway.auth_token doctor posture mismatch"
    }
    if ("$($gatewayRateLimitCheck.status)" -ne "pass" -or "$($gatewayRateLimitCheck.message)" -ne "enabled") {
        throw "gateway.rate_limit doctor posture mismatch"
    }
    if ("$($runtimeStateCheck.status)" -ne "pass") { throw "runtime.state_path doctor check did not pass" }
    if ("$($policyBundleCheck.status)" -ne "pass") { throw "security.policy_bundle doctor check did not pass" }

    if ($audit.StatusCode -ne 200) { throw "security.audit did not return HTTP 200" }
    if ([int]$auditResult.summary.critical -ne 0 -or [int]$auditResult.summary.warn -ne 0 -or [int]$auditResult.summary.info -ne 0) {
        throw "security.audit safe summary mismatch"
    }

    $storeBefore = $statusBeforeResult.store
    if ("$($storeBefore.requestedBackend)" -ne "encrypted-file") { throw "requestedBackend mismatch before set" }
    if ("$($storeBefore.activeBackend)" -ne "encrypted-file") { throw "activeBackend mismatch before set" }
    if (-not [bool]$storeBefore.providerImplemented) { throw "providerImplemented should be true" }
    if ("$($storeBefore.requestedSupport)" -ne "implemented") { throw "requestedSupport mismatch before set" }
    if ([bool]$storeBefore.fallbackApplied) { throw "fallbackApplied should be false" }
    if (-not [bool]$storeBefore.persistent) { throw "secret store should be persistent" }
    if ("$($storeBefore.keySource)" -ne "env:OPENCLAW_ZIG_SECRET_STORE_KEY") { throw "keySource mismatch before set" }

    $set = Invoke-Rpc -Url $rpcUrl -Id "security-store-set" -Method "secrets.store.set" -Params @{ targetId = "tools.web.search.apiKey"; value = "web-secret-zig" } -BearerToken $AuthToken
    if (-not [bool]$set.Json.result.ok) { throw "secrets.store.set ok was false" }
    if ([int]$set.Json.result.count -ne 1) { throw "secrets.store.set count mismatch" }
    if (-not (Test-Path $storeFile)) { throw "secret store file was not written after set" }

    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
        $proc.WaitForExit()
    }

    $proc = Start-Server -Executable $exe -WorkingDirectory $repo -StdoutLog $stdoutLog -StderrLog $stderrLog

    $statusAfter = Invoke-Rpc -Url $rpcUrl -Id "security-store-status-after" -Method "secrets.store.status" -Params @{} -BearerToken $AuthToken
    $get = Invoke-Rpc -Url $rpcUrl -Id "security-store-get" -Method "secrets.store.get" -Params @{ targetId = "tools.web.search.apiKey"; includeValue = $true } -BearerToken $AuthToken
    $list = Invoke-Rpc -Url $rpcUrl -Id "security-store-list" -Method "secrets.store.list" -Params @{} -BearerToken $AuthToken
    $resolve = Invoke-Rpc -Url $rpcUrl -Id "security-store-resolve" -Method "secrets.resolve" -Params @{ commandName = "web search"; targetIds = @("tools.web.search.apiKey") } -BearerToken $AuthToken
    $delete = Invoke-Rpc -Url $rpcUrl -Id "security-store-delete" -Method "secrets.store.delete" -Params @{ targetId = "tools.web.search.apiKey" } -BearerToken $AuthToken

    $storeAfter = $statusAfter.Json.result.store
    if ([int]$storeAfter.count -ne 1) { throw "secrets.store.status after restart count mismatch" }
    if (-not [bool]$get.Json.result.found) { throw "secrets.store.get found was false after restart" }
    if ("$($get.Json.result.value)" -ne "web-secret-zig") { throw "secrets.store.get value mismatch after restart" }
    if ([int]$list.Json.result.count -ne 1) { throw "secrets.store.list count mismatch after restart" }
    if ("$($list.Json.result.items[0].targetId)" -ne "tools.web.search.apiKey") { throw "secrets.store.list item mismatch after restart" }
    if ([int]$resolve.Json.result.resolvedCount -ne 1) { throw "secrets.resolve resolvedCount mismatch" }
    if ("$($resolve.Json.result.assignments[0].value)" -ne "web-secret-zig") { throw "secrets.resolve value mismatch" }
    if (-not [bool]$delete.Json.result.deleted) { throw "secrets.store.delete deleted was false" }
    if ([int]$delete.Json.result.count -ne 0) { throw "secrets.store.delete count mismatch" }

    Write-Output "SECURITY_SECRET_DOCTOR_HTTP=$($doctor.StatusCode)"
    Write-Output "SECURITY_SECRET_AUDIT_HTTP=$($audit.StatusCode)"
    Write-Output "SECURITY_SECRET_GATEWAY_AUTH_OK=$([bool]($gatewayAuthCheck.status -eq 'pass'))"
    Write-Output "SECURITY_SECRET_GATEWAY_RATE_LIMIT_OK=$([bool]($gatewayRateLimitCheck.status -eq 'pass'))"
    Write-Output "SECURITY_SECRET_AUDIT_WARN_COUNT=$($auditResult.summary.warn)"
    Write-Output "SECURITY_SECRET_AUDIT_CRITICAL_COUNT=$($auditResult.summary.critical)"
    Write-Output "SECURITY_SECRET_BACKEND=$($storeBefore.activeBackend)"
    Write-Output "SECURITY_SECRET_PERSISTENT=$([bool]$storeBefore.persistent)"
    Write-Output "SECURITY_SECRET_STORE_FILE_EXISTS=$([bool](Test-Path $storeFile))"
    Write-Output "SECURITY_SECRET_RELOAD_FOUND=$([bool]$get.Json.result.found)"
    Write-Output "SECURITY_SECRET_RESOLVED_COUNT=$($resolve.Json.result.resolvedCount)"
    Write-Output "SECURITY_SECRET_DELETE_OK=$([bool]$delete.Json.result.deleted)"
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
    Remove-Item Env:OPENCLAW_ZIG_SECRET_BACKEND -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_SECRET_STORE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_SECRET_STORE_KEY -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_STATE_PATH -ErrorAction SilentlyContinue
    Remove-Item Env:OPENCLAW_ZIG_SECURITY_POLICY_BUNDLE_PATH -ErrorAction SilentlyContinue
    if (-not $KeepLogs) {
        Remove-Item $stdoutLog,$stderrLog -ErrorAction SilentlyContinue
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
