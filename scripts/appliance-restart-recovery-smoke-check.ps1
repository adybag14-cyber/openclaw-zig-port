param(
    [int] $Port = 8098,
    [int] $ReadyAttempts = 80,
    [int] $ReadySleepMs = 500,
    [switch] $SkipBuild,
    [switch] $KeepLogs
)

$ErrorActionPreference = "Stop"

$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$stateRoot = Join-Path $repo "tmp_smoke_appliance_recovery_state"

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

function Start-AgentInstance {
    param(
        [string] $ExePath,
        [string] $RepoPath,
        [string] $Label
    )

    $stdoutLog = Join-Path $RepoPath ("tmp_smoke_appliance_recovery_{0}_stdout.log" -f $Label)
    $stderrLog = Join-Path $RepoPath ("tmp_smoke_appliance_recovery_{0}_stderr.log" -f $Label)
    Remove-Item $stdoutLog, $stderrLog -ErrorAction SilentlyContinue

    $proc = Start-Process -FilePath $ExePath -ArgumentList @("--serve") -WorkingDirectory $RepoPath -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
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
        throw "openclaw-zig did not become ready on $baseUrl for $Label (exit=$exitCode)`nSTDERR:`n$stderrTail`nSTDOUT:`n$stdoutTail"
    }

    return @{
        Process = $proc
        BaseUrl = $baseUrl
        StdoutLog = $stdoutLog
        StderrLog = $stderrLog
    }
}

function Stop-AgentInstance {
    param($Instance)

    if ($null -ne $Instance -and $null -ne $Instance.Process -and -not $Instance.Process.HasExited) {
        Stop-Process -Id $Instance.Process.Id -Force
        Start-Sleep -Milliseconds 300
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

$previousHttpPort = $env:OPENCLAW_ZIG_HTTP_PORT
$previousStatePath = $env:OPENCLAW_ZIG_STATE_PATH
$previousAttestKey = $env:OPENCLAW_ZIG_BOOT_ATTEST_KEY

Remove-Item $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stateRoot | Out-Null

$env:OPENCLAW_ZIG_HTTP_PORT = "$Port"
$env:OPENCLAW_ZIG_STATE_PATH = $stateRoot
$env:OPENCLAW_ZIG_BOOT_ATTEST_KEY = "appliance-restart-recovery-key"

$first = $null
$second = $null

try {
    $first = Start-AgentInstance -ExePath $exe -RepoPath $repo -Label "first"
    $firstRpcUrl = "$($first.BaseUrl)/rpc"

    $statusFirst = Invoke-Rpc -Url $firstRpcUrl -Id "appliance-recovery-status-first" -Method "status" -Params @{}
    Require-Equal -Name "status first runtime persisted" -Actual $statusFirst.Json.result.runtime.persisted -Expected $true

    $bootPolicySet = Invoke-Rpc -Url $firstRpcUrl -Id "appliance-recovery-policy-set" -Method "system.boot.policy.set" -Params @{
        policy = "signature-required"
        enforceUpdateGate = $true
        verificationMaxAgeMs = 300000
        requiredSigner = "sigstore"
    }
    Require-Equal -Name "policy set enforce gate" -Actual $bootPolicySet.Json.result.secureBoot.enforceUpdateGate -Expected $true

    $bootVerifyOk = Invoke-Rpc -Url $firstRpcUrl -Id "appliance-recovery-verify-ok" -Method "system.boot.verify" -Params @{
        measurement = "hash-restart-1"
        expectedHash = "hash-restart-1"
        signer = "sigstore"
    }
    Require-Equal -Name "verify ok before restart" -Actual $bootVerifyOk.Json.result.verified -Expected $true

    $updateAllowed = Invoke-Rpc -Url $firstRpcUrl -Id "appliance-recovery-update-allowed" -Method "update.run" -Params @{
        targetVersion = "edge-next"
        force = $true
    }
    Require-Equal -Name "update allowed before restart" -Actual $updateAllowed.Json.result.status -Expected "completed"

    $rollbackPlan = Invoke-Rpc -Url $firstRpcUrl -Id "appliance-recovery-rollback-plan" -Method "system.rollback.plan" -Params @{
        targetSlot = "B"
        reason = "recovery-check"
    }
    Require-Equal -Name "rollback plan before restart" -Actual $rollbackPlan.Json.result.status -Expected "planned"
    Require-Equal -Name "rollback pending before restart" -Actual $rollbackPlan.Json.result.pending -Expected $true

    Stop-AgentInstance -Instance $first
    $first = $null

    $compatStatePath = Join-Path $stateRoot "compat-state.json"
    Require-True -Name "compat-state file exists" -Actual (Test-Path $compatStatePath)

    $compatPersisted = Get-Content $compatStatePath -Raw | ConvertFrom-Json
    Require-Equal -Name "persisted boot policy" -Actual $compatPersisted.bootPolicy -Expected "signature-required"
    Require-Equal -Name "persisted boot verified" -Actual $compatPersisted.bootLastVerified -Expected $true
    Require-Equal -Name "persisted current version" -Actual $compatPersisted.updateCurrentVersion -Expected "edge-next"
    Require-Equal -Name "persisted rollback pending" -Actual $compatPersisted.rollbackPending -Expected $true
    Require-Equal -Name "persisted rollback target" -Actual $compatPersisted.rollbackTargetSlot -Expected "B"

    $second = Start-AgentInstance -ExePath $exe -RepoPath $repo -Label "second"
    $secondRpcUrl = "$($second.BaseUrl)/rpc"

    $statusSecond = Invoke-Rpc -Url $secondRpcUrl -Id "appliance-recovery-status-second" -Method "status" -Params @{}
    Require-Equal -Name "status second runtime persisted" -Actual $statusSecond.Json.result.runtime.persisted -Expected $true
    Require-Equal -Name "status second recovery backlog" -Actual $statusSecond.Json.result.runtime.recoveryBacklog -Expected 0

    $bootStatusSecond = Invoke-Rpc -Url $secondRpcUrl -Id "appliance-recovery-boot-status-second" -Method "system.boot.status" -Params @{}
    Require-Equal -Name "boot status second active slot" -Actual $bootStatusSecond.Json.result.secureBoot.activeSlot -Expected "A"
    Require-Equal -Name "boot status second policy" -Actual $bootStatusSecond.Json.result.secureBoot.policy -Expected "signature-required"
    Require-Equal -Name "boot status second gate" -Actual $bootStatusSecond.Json.result.secureBoot.enforceUpdateGate -Expected $true
    Require-Equal -Name "boot status second signer" -Actual $bootStatusSecond.Json.result.secureBoot.requiredSigner -Expected "sigstore"
    Require-Equal -Name "boot status second verified" -Actual $bootStatusSecond.Json.result.secureBoot.lastVerified -Expected $true
    Require-Equal -Name "boot status second measurement" -Actual $bootStatusSecond.Json.result.secureBoot.lastMeasurement -Expected "hash-restart-1"
    Require-Equal -Name "boot status second rollback pending" -Actual $bootStatusSecond.Json.result.rollback.pending -Expected $true
    Require-Equal -Name "boot status second rollback target" -Actual $bootStatusSecond.Json.result.rollback.targetSlot -Expected "B"
    Require-Equal -Name "boot status second gate allowed" -Actual $bootStatusSecond.Json.result.updateGate.allowed -Expected $true

    $updateStatus = Invoke-Rpc -Url $secondRpcUrl -Id "appliance-recovery-update-status" -Method "update.status" -Params @{ limit = 10 }
    Require-Equal -Name "update status current version after restart" -Actual $updateStatus.Json.result.currentVersion -Expected "edge-next"
    Require-Equal -Name "update status current channel after restart" -Actual $updateStatus.Json.result.currentChannel -Expected "edge"
    Require-Equal -Name "update status latest target after restart" -Actual $updateStatus.Json.result.latestRun.targetVersion -Expected "edge-next"

    $rollbackCancel = Invoke-Rpc -Url $secondRpcUrl -Id "appliance-recovery-rollback-cancel" -Method "system.rollback.cancel" -Params @{}
    Require-Equal -Name "rollback cancel after restart status" -Actual $rollbackCancel.Json.result.status -Expected "cancelled"
    Require-Equal -Name "rollback cancel after restart target" -Actual $rollbackCancel.Json.result.cancelledTarget -Expected "B"

    $bootStatusSettled = Invoke-Rpc -Url $secondRpcUrl -Id "appliance-recovery-boot-status-settled" -Method "system.boot.status" -Params @{}
    Require-Equal -Name "boot status settled rollback pending" -Actual $bootStatusSettled.Json.result.rollback.pending -Expected $false

    Write-Output "APPLIANCE_RECOVERY_STATUS_FIRST_HTTP=$($statusFirst.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_POLICY_SET_HTTP=$($bootPolicySet.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_VERIFY_OK_HTTP=$($bootVerifyOk.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_UPDATE_ALLOWED_HTTP=$($updateAllowed.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_ROLLBACK_PLAN_HTTP=$($rollbackPlan.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_STATUS_SECOND_HTTP=$($statusSecond.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_BOOT_STATUS_SECOND_HTTP=$($bootStatusSecond.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_UPDATE_STATUS_HTTP=$($updateStatus.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_ROLLBACK_CANCEL_HTTP=$($rollbackCancel.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_BOOT_STATUS_SETTLED_HTTP=$($bootStatusSettled.StatusCode)"
    Write-Output "APPLIANCE_RECOVERY_COMPAT_FILE=$compatStatePath"
    Write-Output "APPLIANCE_RECOVERY_VERSION_AFTER=$($updateStatus.Json.result.currentVersion)"
    Write-Output "APPLIANCE_RECOVERY_ROLLBACK_PENDING_AFTER_RESTART=$($bootStatusSecond.Json.result.rollback.pending)"
    Write-Output "APPLIANCE_RECOVERY_ROLLBACK_PENDING_SETTLED=$($bootStatusSettled.Json.result.rollback.pending)"
}
finally {
    Stop-AgentInstance -Instance $first
    Stop-AgentInstance -Instance $second

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
        Remove-Item (Join-Path $repo "tmp_smoke_appliance_recovery_first_stdout.log") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $repo "tmp_smoke_appliance_recovery_first_stderr.log") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $repo "tmp_smoke_appliance_recovery_second_stdout.log") -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $repo "tmp_smoke_appliance_recovery_second_stderr.log") -ErrorAction SilentlyContinue
        Remove-Item $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
