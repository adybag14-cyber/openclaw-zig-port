param(
    [int] $Port = 8100,
    [int] $ReadyAttempts = 80,
    [int] $ReadySleepMs = 500,
    [string] $AuthToken = "appliance-profile-token",
    [switch] $SkipBuild,
    [switch] $KeepLogs
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stateDir = Join-Path $repo "tmp_smoke_appliance_profile_state"

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

    throw "Zig executable not found. Set OPENCLAW_ZIG_BIN or ensure `zig` is on PATH."
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
    } | ConvertTo-Json -Depth 12 -Compress

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
    $resp = Invoke-WebRequest @req
    $json = $resp.Content | ConvertFrom-Json
    if ($null -ne $json.error) {
        throw "RPC $Method returned error: $($json.error | ConvertTo-Json -Depth 8 -Compress)"
    }
    return @{
        StatusCode = $resp.StatusCode
        Json = $json
    }
}

function Require-Equal {
    param(
        [string] $Name,
        $Actual,
        $Expected
    )

    if ("$Actual" -ne "$Expected") {
        throw "$Name expected '$Expected', got '$Actual'"
    }
}

function Require-True {
    param(
        [string] $Name,
        $Actual
    )

    if (-not [bool]$Actual) {
        throw "$Name expected true"
    }
}

$zig = Resolve-ZigExecutable
if (-not $SkipBuild) {
    & $zig build --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE"
    }
}

$exe = Resolve-AgentExecutable -RepoPath $repo
Remove-Item $stateDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stateDir | Out-Null

$stdoutLog = Join-Path $repo "tmp_smoke_appliance_profile_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_appliance_profile_stderr.log"
Remove-Item $stdoutLog, $stderrLog -ErrorAction SilentlyContinue

$previousHttpPort = $env:OPENCLAW_ZIG_HTTP_PORT
$previousStatePath = $env:OPENCLAW_ZIG_STATE_PATH
$previousAuthToken = $env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN
$previousRequireToken = $env:OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN
$previousAttestKey = $env:OPENCLAW_ZIG_BOOT_ATTEST_KEY

$env:OPENCLAW_ZIG_HTTP_PORT = "$Port"
$env:OPENCLAW_ZIG_STATE_PATH = $stateDir
$env:OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN = "true"
$env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN = $AuthToken
$env:OPENCLAW_ZIG_BOOT_ATTEST_KEY = "appliance-profile-smoke-key"

$proc = Start-Process -FilePath $exe -ArgumentList @("--serve") -WorkingDirectory $repo -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
$baseUrl = "http://127.0.0.1:$Port"
$rpcUrl = "$baseUrl/rpc"
$headers = @{ Authorization = "Bearer $AuthToken" }

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
    $statusBefore = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-status-before" -Method "status" -Params @{} -Headers $headers
    Require-Equal -Name "status before http" -Actual $statusBefore.StatusCode -Expected 200
    if ($null -eq $statusBefore.Json.result.applianceProfile) {
        throw "status before missing applianceProfile: $($statusBefore.Json.result | ConvertTo-Json -Depth 20 -Compress)"
    }
    Require-Equal -Name "profile before ready" -Actual $statusBefore.Json.result.applianceProfile.ready -Expected $false
    Require-Equal -Name "profile before status" -Actual $statusBefore.Json.result.applianceProfile.status -Expected "not_ready"

    $doctorBefore = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-doctor-before" -Method "doctor" -Params @{} -Headers $headers
    Require-Equal -Name "doctor before ready" -Actual $doctorBefore.Json.result.applianceProfile.ready -Expected $false
    $doctorProfileCheck = @($doctorBefore.Json.result.checks | Where-Object { $_.id -eq "appliance.profile" })
    Require-True -Name "doctor profile check before exists" -Actual ($doctorProfileCheck.Count -eq 1)
    Require-Equal -Name "doctor profile check before status" -Actual $doctorProfileCheck[0].status -Expected "fail"

    $maintenanceBefore = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-maint-before" -Method "system.maintenance.plan" -Params @{} -Headers $headers
    Require-Equal -Name "maintenance before ready" -Actual $maintenanceBefore.Json.result.applianceProfile.ready -Expected $false
    $maintenanceBeforeAction = @($maintenanceBefore.Json.result.actions | Where-Object { $_.id -eq "appliance.profile.minimal" })
    Require-True -Name "maintenance before appliance action exists" -Actual ($maintenanceBeforeAction.Count -ge 1)

    $bootPolicySet = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-boot-policy" -Method "system.boot.policy.set" -Params @{
        policy = "signature-required"
        enforceUpdateGate = $true
        verificationMaxAgeMs = 300000
        requiredSigner = "sigstore"
    } -Headers $headers
    Require-Equal -Name "boot policy set enforce gate" -Actual $bootPolicySet.Json.result.secureBoot.enforceUpdateGate -Expected $true

    $bootVerify = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-boot-verify" -Method "system.boot.verify" -Params @{
        measurement = "appliance-profile-hash"
        expectedHash = "appliance-profile-hash"
        signer = "sigstore"
    } -Headers $headers
    Require-Equal -Name "boot verify ok" -Actual $bootVerify.Json.result.verified -Expected $true

    $bootStatusAfter = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-boot-status-after" -Method "system.boot.status" -Params @{} -Headers $headers
    Require-Equal -Name "boot status after ready" -Actual $bootStatusAfter.Json.result.applianceProfile.ready -Expected $true
    Require-Equal -Name "boot status after status" -Actual $bootStatusAfter.Json.result.applianceProfile.status -Expected "ready"

    $statusAfter = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-status-after" -Method "status" -Params @{} -Headers $headers
    Require-Equal -Name "status after ready" -Actual $statusAfter.Json.result.applianceProfile.ready -Expected $true
    Require-Equal -Name "status after status" -Actual $statusAfter.Json.result.applianceProfile.status -Expected "ready"

    $doctorAfter = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-doctor-after" -Method "doctor" -Params @{} -Headers $headers
    Require-Equal -Name "doctor after ready" -Actual $doctorAfter.Json.result.applianceProfile.ready -Expected $true
    $doctorProfileCheckAfter = @($doctorAfter.Json.result.checks | Where-Object { $_.id -eq "appliance.profile" })
    Require-True -Name "doctor profile check after exists" -Actual ($doctorProfileCheckAfter.Count -eq 1)
    Require-Equal -Name "doctor profile check after status" -Actual $doctorProfileCheckAfter[0].status -Expected "pass"

    $maintenanceAfter = Invoke-Rpc -Url $rpcUrl -Id "appliance-profile-maint-after" -Method "system.maintenance.plan" -Params @{} -Headers $headers
    Require-Equal -Name "maintenance after ready" -Actual $maintenanceAfter.Json.result.applianceProfile.ready -Expected $true
    $maintenanceAfterAction = @($maintenanceAfter.Json.result.actions | Where-Object { $_.id -eq "appliance.profile.minimal" })
    Require-Equal -Name "maintenance after appliance action count" -Actual $maintenanceAfterAction.Count -Expected 0

    Write-Output "APPLIANCE_PROFILE_INITIAL_READY=$($statusBefore.Json.result.applianceProfile.ready)"
    Write-Output "APPLIANCE_PROFILE_INITIAL_STATUS=$($statusBefore.Json.result.applianceProfile.status)"
    Write-Output "APPLIANCE_PROFILE_FINAL_READY=$($statusAfter.Json.result.applianceProfile.ready)"
    Write-Output "APPLIANCE_PROFILE_FINAL_STATUS=$($statusAfter.Json.result.applianceProfile.status)"
    Write-Output "APPLIANCE_PROFILE_DOCTOR_CHECK_AFTER=$($doctorProfileCheckAfter[0].status)"
    Write-Output "APPLIANCE_PROFILE_MAINT_ACTION_BEFORE=$($maintenanceBeforeAction.Count -ge 1)"
    Write-Output "APPLIANCE_PROFILE_MAINT_ACTION_AFTER=$($maintenanceAfterAction.Count -ge 1)"
}
finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }

    if ($null -eq $previousHttpPort) { Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue } else { $env:OPENCLAW_ZIG_HTTP_PORT = $previousHttpPort }
    if ($null -eq $previousStatePath) { Remove-Item Env:OPENCLAW_ZIG_STATE_PATH -ErrorAction SilentlyContinue } else { $env:OPENCLAW_ZIG_STATE_PATH = $previousStatePath }
    if ($null -eq $previousAuthToken) { Remove-Item Env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN -ErrorAction SilentlyContinue } else { $env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN = $previousAuthToken }
    if ($null -eq $previousRequireToken) { Remove-Item Env:OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN -ErrorAction SilentlyContinue } else { $env:OPENCLAW_ZIG_GATEWAY_REQUIRE_TOKEN = $previousRequireToken }
    if ($null -eq $previousAttestKey) { Remove-Item Env:OPENCLAW_ZIG_BOOT_ATTEST_KEY -ErrorAction SilentlyContinue } else { $env:OPENCLAW_ZIG_BOOT_ATTEST_KEY = $previousAttestKey }

    if (-not $KeepLogs) {
        Remove-Item $stdoutLog, $stderrLog -ErrorAction SilentlyContinue
        Remove-Item $stateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
