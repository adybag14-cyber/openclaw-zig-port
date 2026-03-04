param(
    [int] $Port = 8096,
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

$zig = Resolve-ZigExecutable
if (-not $SkipBuild) {
    & $zig build --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE"
    }
}

$exe = Resolve-AgentExecutable -RepoPath $repo

$env:OPENCLAW_ZIG_HTTP_PORT = "$Port"
$stdoutLog = Join-Path $repo "tmp_smoke_maintenance_stdout.log"
$stderrLog = Join-Path $repo "tmp_smoke_maintenance_stderr.log"
Remove-Item $stdoutLog, $stderrLog -ErrorAction SilentlyContinue

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

    $plan = Invoke-Rpc -Url $rpcUrl -Id "maint-plan" -Method "system.maintenance.plan" -Params @{ deep = $false }
    if (-not $plan.Json.result.ok) {
        throw "system.maintenance.plan did not return ok=true"
    }

    $runDry = Invoke-Rpc -Url $rpcUrl -Id "maint-run-dry" -Method "system.maintenance.run" -Params @{
        deep = $false
        dryRun = $true
    }
    if ("$($runDry.Json.result.status)" -ne "planned") {
        throw "system.maintenance.run dryRun expected status=planned, got $($runDry.Json.result.status)"
    }

    $runApply = Invoke-Rpc -Url $rpcUrl -Id "maint-run-apply" -Method "system.maintenance.run" -Params @{
        deep = $false
        dryRun = $false
    }
    $runApplyStatus = "$($runApply.Json.result.status)"
    if ($runApplyStatus -notin @("completed", "completed_with_errors")) {
        throw "system.maintenance.run apply returned unexpected status '$runApplyStatus'"
    }
    $runApplyJobId = "$($runApply.Json.result.updateJob.jobId)"
    if ([string]::IsNullOrWhiteSpace($runApplyJobId)) {
        throw "system.maintenance.run apply missing updateJob.jobId"
    }

    $status = Invoke-Rpc -Url $rpcUrl -Id "maint-status" -Method "system.maintenance.status" -Params @{ deep = $false }
    if (-not $status.Json.result.ok) {
        throw "system.maintenance.status did not return ok=true"
    }
    $latestJobId = "$($status.Json.result.latestRun.jobId)"
    if ([string]::IsNullOrWhiteSpace($latestJobId)) {
        throw "system.maintenance.status missing latestRun.jobId after apply run"
    }

    Write-Output "MAINT_PLAN_HTTP=$($plan.StatusCode)"
    Write-Output "MAINT_RUN_DRY_HTTP=$($runDry.StatusCode)"
    Write-Output "MAINT_RUN_APPLY_HTTP=$($runApply.StatusCode)"
    Write-Output "MAINT_STATUS_HTTP=$($status.StatusCode)"
    Write-Output "MAINT_PLAN_HEALTH_SCORE=$($plan.Json.result.healthScore)"
    Write-Output "MAINT_RUN_DRY_STATUS=$($runDry.Json.result.status)"
    Write-Output "MAINT_RUN_APPLY_STATUS=$runApplyStatus"
    Write-Output "MAINT_STATUS_CURRENT=$($status.Json.result.status)"
    Write-Output "MAINT_STATUS_PENDING_ACTIONS=$($status.Json.result.pendingActions)"
    Write-Output "MAINT_RUN_APPLY_JOB_ID=$runApplyJobId"
    Write-Output "MAINT_STATUS_LATEST_JOB_ID=$latestJobId"
}
finally {
    if ($null -ne $proc -and -not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }
    Remove-Item Env:OPENCLAW_ZIG_HTTP_PORT -ErrorAction SilentlyContinue
    if (-not $KeepLogs) {
        Remove-Item $stdoutLog, $stderrLog -ErrorAction SilentlyContinue
    }
}
