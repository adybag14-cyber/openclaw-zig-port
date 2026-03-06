param(
    [int] $Port = 8097,
    [int] $ReadyAttempts = 80,
    [int] $ReadySleepMs = 500,
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
        [hashtable] $Params
    )

    $payload = @{
        id = $Id
        method = $Method
        params = if ($null -eq $Params) { @{} } else { $Params }
    } | ConvertTo-Json -Depth 12 -Compress

    $resp = Invoke-WebRequest -Uri $Url -Method Post -ContentType "application/json" -Body $payload -UseBasicParsing
    $json = $resp.Content | ConvertFrom-Json
    if ($null -ne $json.error) {
        throw "RPC $Method returned error: $($json.error | ConvertTo-Json -Depth 8 -Compress)"
    }
    return @{
        StatusCode = $resp.StatusCode
        Json = $json
        Content = $resp.Content
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

$stdoutLog = Join-Path $repo "tmp_smoke_appliance_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_appliance_stderr.log"
Remove-Item $stdoutLog, $stderrLog -ErrorAction SilentlyContinue

$previousHttpPort = $env:OPENCLAW_ZIG_HTTP_PORT
$previousStatePath = $env:OPENCLAW_ZIG_STATE_PATH
$previousAttestKey = $env:OPENCLAW_ZIG_BOOT_ATTEST_KEY

$env:OPENCLAW_ZIG_HTTP_PORT = "$Port"
$env:OPENCLAW_ZIG_STATE_PATH = "memory://appliance-control-plane-smoke"
$env:OPENCLAW_ZIG_BOOT_ATTEST_KEY = "appliance-control-plane-smoke-key"

$proc = Start-Process -FilePath $exe -ArgumentList @("--serve") -WorkingDirectory $repo -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
$baseUrl = "http://127.0.0.1:$Port"

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
    $rpcUrl = "$baseUrl/rpc"

    $bootStatus = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-status" -Method "system.boot.status" -Params @{}
    Require-Equal -Name "boot status active slot" -Actual $bootStatus.Json.result.secureBoot.activeSlot -Expected "A"
    Require-Equal -Name "boot status rollback pending" -Actual $bootStatus.Json.result.rollback.pending -Expected $false

    $bootPolicy = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-policy-get" -Method "system.boot.policy.get" -Params @{}
    Require-True -Name "boot policy has secureBoot" -Actual ($null -ne $bootPolicy.Json.result.secureBoot)
    Require-True -Name "boot policy has updateGate" -Actual ($null -ne $bootPolicy.Json.result.updateGate)

    $bootPolicySet = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-policy-set" -Method "system.boot.policy.set" -Params @{
        policy = "signature-required"
        enforceUpdateGate = $true
        verificationMaxAgeMs = 300000
        requiredSigner = "sigstore"
    }
    Require-Equal -Name "boot policy set enforce gate" -Actual $bootPolicySet.Json.result.secureBoot.enforceUpdateGate -Expected $true

    $bootVerifyFail = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-verify-fail" -Method "system.boot.verify" -Params @{
        measurement = "mismatch-a"
        expectedHash = "mismatch-b"
        signer = "sigstore"
    }
    Require-Equal -Name "boot verify fail verified" -Actual $bootVerifyFail.Json.result.verified -Expected $false

    $updateBlocked = Invoke-Rpc -Url $rpcUrl -Id "appliance-update-blocked" -Method "update.run" -Params @{
        targetVersion = "edge-next"
    }
    Require-Equal -Name "blocked update ok" -Actual $updateBlocked.Json.result.ok -Expected $false
    Require-Equal -Name "blocked update status" -Actual $updateBlocked.Json.result.status -Expected "failed"
    Require-Equal -Name "blocked update gate flag" -Actual $updateBlocked.Json.result.blockedBySecureBoot -Expected $true

    $bootVerifyOk = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-verify-ok" -Method "system.boot.verify" -Params @{
        measurement = "hash-1"
        expectedHash = "hash-1"
        signer = "sigstore"
    }
    Require-Equal -Name "boot verify ok verified" -Actual $bootVerifyOk.Json.result.verified -Expected $true
    Require-Equal -Name "boot verify ok gate allowed" -Actual $bootVerifyOk.Json.result.updateGate.allowed -Expected $true

    $bootAttest = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-attest" -Method "system.boot.attest" -Params @{
        nonce = "appliance-nonce-1"
    }
    $attestation = $bootAttest.Json.result.attestation
    Require-Equal -Name "boot attest key configured" -Actual $attestation.keyConfigured -Expected $true
    Require-Equal -Name "boot attest signature algorithm" -Actual $attestation.signatureAlgorithm -Expected "hmac-sha256"
    Require-Equal -Name "boot attest nonce" -Actual $attestation.nonce -Expected "appliance-nonce-1"

    $bootAttestVerify = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-attest-verify" -Method "system.boot.attest.verify" -Params @{
        statement = "$($attestation.statement)"
        statementDigest = "$($attestation.statementDigest)"
        signature = "$($attestation.signature)"
        nonce = "appliance-nonce-1"
        maxAgeMs = 300000
        requireSignature = $true
    }
    Require-Equal -Name "boot attest verify valid" -Actual $bootAttestVerify.Json.result.valid -Expected $true
    Require-Equal -Name "boot attest verify nonce" -Actual $bootAttestVerify.Json.result.nonceMatch -Expected $true
    Require-Equal -Name "boot attest verify signature" -Actual $bootAttestVerify.Json.result.signatureValid -Expected $true

    $updateAllowed = Invoke-Rpc -Url $rpcUrl -Id "appliance-update-allowed" -Method "update.run" -Params @{
        targetVersion = "edge-next"
        force = $true
    }
    Require-Equal -Name "allowed update ok" -Actual $updateAllowed.Json.result.ok -Expected $true
    Require-Equal -Name "allowed update status" -Actual $updateAllowed.Json.result.status -Expected "completed"

    $rollbackPlan = Invoke-Rpc -Url $rpcUrl -Id "appliance-rollback-plan" -Method "system.rollback.plan" -Params @{
        targetSlot = "B"
        reason = "canary-failure"
    }
    Require-Equal -Name "rollback plan status" -Actual $rollbackPlan.Json.result.status -Expected "planned"
    Require-Equal -Name "rollback plan pending" -Actual $rollbackPlan.Json.result.pending -Expected $true

    $rollbackCancel = Invoke-Rpc -Url $rpcUrl -Id "appliance-rollback-cancel" -Method "system.rollback.cancel" -Params @{}
    Require-Equal -Name "rollback cancel status" -Actual $rollbackCancel.Json.result.status -Expected "cancelled"
    Require-Equal -Name "rollback cancel pending" -Actual $rollbackCancel.Json.result.pending -Expected $false
    Require-Equal -Name "rollback cancel target" -Actual $rollbackCancel.Json.result.cancelledTarget -Expected "B"

    $rollbackPlanAgain = Invoke-Rpc -Url $rpcUrl -Id "appliance-rollback-plan-again" -Method "system.rollback.plan" -Params @{
        targetSlot = "B"
        reason = "canary-failure-2"
    }
    Require-Equal -Name "rollback re-plan status" -Actual $rollbackPlanAgain.Json.result.status -Expected "planned"
    Require-Equal -Name "rollback re-plan pending" -Actual $rollbackPlanAgain.Json.result.pending -Expected $true

    $rollbackDryRun = Invoke-Rpc -Url $rpcUrl -Id "appliance-rollback-dry-run" -Method "system.rollback.run" -Params @{
        targetSlot = "B"
        dryRun = $true
    }
    Require-Equal -Name "rollback dry-run status" -Actual $rollbackDryRun.Json.result.status -Expected "planned"
    Require-Equal -Name "rollback dry-run applied" -Actual $rollbackDryRun.Json.result.applied -Expected $false
    Require-Equal -Name "rollback dry-run pending" -Actual $rollbackDryRun.Json.result.pending -Expected $true

    $rollbackApply = Invoke-Rpc -Url $rpcUrl -Id "appliance-rollback-apply" -Method "system.rollback.run" -Params @{
        targetSlot = "B"
        apply = $true
    }
    Require-Equal -Name "rollback apply status" -Actual $rollbackApply.Json.result.status -Expected "applied"
    Require-Equal -Name "rollback apply active slot" -Actual $rollbackApply.Json.result.activeSlot -Expected "B"
    Require-Equal -Name "rollback apply pending" -Actual $rollbackApply.Json.result.pending -Expected $false

    $bootStatusAfter = Invoke-Rpc -Url $rpcUrl -Id "appliance-boot-status-after" -Method "system.boot.status" -Params @{}
    Require-Equal -Name "boot status after active slot" -Actual $bootStatusAfter.Json.result.secureBoot.activeSlot -Expected "B"
    Require-Equal -Name "boot status after rollback pending" -Actual $bootStatusAfter.Json.result.rollback.pending -Expected $false

    Write-Output "APPLIANCE_BOOT_STATUS_HTTP=$($bootStatus.StatusCode)"
    Write-Output "APPLIANCE_BOOT_POLICY_HTTP=$($bootPolicy.StatusCode)"
    Write-Output "APPLIANCE_BOOT_VERIFY_FAIL_HTTP=$($bootVerifyFail.StatusCode)"
    Write-Output "APPLIANCE_UPDATE_BLOCKED_HTTP=$($updateBlocked.StatusCode)"
    Write-Output "APPLIANCE_BOOT_VERIFY_OK_HTTP=$($bootVerifyOk.StatusCode)"
    Write-Output "APPLIANCE_BOOT_ATTEST_HTTP=$($bootAttest.StatusCode)"
    Write-Output "APPLIANCE_BOOT_ATTEST_VERIFY_HTTP=$($bootAttestVerify.StatusCode)"
    Write-Output "APPLIANCE_UPDATE_ALLOWED_HTTP=$($updateAllowed.StatusCode)"
    Write-Output "APPLIANCE_ROLLBACK_PLAN_HTTP=$($rollbackPlan.StatusCode)"
    Write-Output "APPLIANCE_ROLLBACK_CANCEL_HTTP=$($rollbackCancel.StatusCode)"
    Write-Output "APPLIANCE_ROLLBACK_DRY_HTTP=$($rollbackDryRun.StatusCode)"
    Write-Output "APPLIANCE_ROLLBACK_APPLY_HTTP=$($rollbackApply.StatusCode)"
    Write-Output "APPLIANCE_BOOT_STATUS_AFTER_HTTP=$($bootStatusAfter.StatusCode)"
    Write-Output "APPLIANCE_UPDATE_BLOCKED_STATUS=$($updateBlocked.Json.result.status)"
    Write-Output "APPLIANCE_UPDATE_ALLOWED_STATUS=$($updateAllowed.Json.result.status)"
    Write-Output "APPLIANCE_ATTEST_SIGNATURE_ALGO=$($attestation.signatureAlgorithm)"
    Write-Output "APPLIANCE_ATTEST_VERIFY_VALID=$($bootAttestVerify.Json.result.valid)"
    Write-Output "APPLIANCE_ACTIVE_SLOT_AFTER=$($bootStatusAfter.Json.result.secureBoot.activeSlot)"
}
finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }

    if ($null -eq $previousHttpPort) {
        Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
    } else {
        $env:OPENCLAW_ZIG_HTTP_PORT = $previousHttpPort
    }

    if ($null -eq $previousStatePath) {
        Remove-Item Env:OPENCLAW_ZIG_STATE_PATH -ErrorAction SilentlyContinue
    } else {
        $env:OPENCLAW_ZIG_STATE_PATH = $previousStatePath
    }

    if ($null -eq $previousAttestKey) {
        Remove-Item Env:OPENCLAW_ZIG_BOOT_ATTEST_KEY -ErrorAction SilentlyContinue
    } else {
        $env:OPENCLAW_ZIG_BOOT_ATTEST_KEY = $previousAttestKey
    }

    if (-not $KeepLogs) {
        Remove-Item $stdoutLog, $stderrLog -ErrorAction SilentlyContinue
    }
}
