param(
    [switch] $SkipBuild
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

function Invoke-ChildScript {
    param(
        [string] $Name,
        [string] $ScriptPath,
        [switch] $ForwardSkipBuild
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "$Name script not found: $ScriptPath"
    }

    $args = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath
    )
    if ($ForwardSkipBuild) {
        $args += "-SkipBuild"
    }

    $stdoutPath = Join-Path $repo ("tmp_{0}_stdout.log" -f $Name.Replace('-', '_'))
    $stderrPath = Join-Path $repo ("tmp_{0}_stderr.log" -f $Name.Replace('-', '_'))
    Remove-Item $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $args -WorkingDirectory $repo -PassThru -Wait -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    $output = @()
    if (Test-Path $stdoutPath) {
        $output += Get-Content $stdoutPath -ErrorAction SilentlyContinue
    }
    if (Test-Path $stderrPath) {
        $output += Get-Content $stderrPath -ErrorAction SilentlyContinue
    }

    if ($proc.ExitCode -ne 0) {
        $joined = (($output | ForEach-Object { "$_" }) -join "`n")
        throw "$Name failed with exit code $($proc.ExitCode)`n$joined"
    }

    $values = @{}
    foreach ($line in $output) {
        $text = "$line".Trim()
        if ($text -match '^([A-Z0-9_]+)=(.*)$') {
            $values[$matches[1]] = $matches[2]
        }
    }

    return @{
        Name = $Name
        Output = @($output | ForEach-Object { "$_" })
        Values = $values
    }
}

function Require-Equal {
    param(
        [hashtable] $Map,
        [string] $Key,
        [string] $Expected,
        [string] $Context
    )

    if (-not $Map.ContainsKey($Key)) {
        throw "$Context missing required receipt: $Key"
    }

    if ("$($Map[$Key])" -ne $Expected) {
        throw "$Context expected $Key=$Expected, got $($Map[$Key])"
    }
}

function Require-OneOf {
    param(
        [hashtable] $Map,
        [string] $Key,
        [string[]] $Expected,
        [string] $Context
    )

    if (-not $Map.ContainsKey($Key)) {
        throw "$Context missing required receipt: $Key"
    }

    $actual = "$($Map[$Key])"
    if ($Expected -notcontains $actual) {
        throw "$Context expected $Key in [$($Expected -join ', ')], got $actual"
    }
}

$zig = Resolve-ZigExecutable

if (-not $SkipBuild) {
    & $zig build --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "zig build failed with exit code $LASTEXITCODE"
    }

    & $zig build baremetal -Doptimize=ReleaseFast -Dbaremetal-qemu-smoke=true --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "zig build baremetal failed with exit code $LASTEXITCODE"
    }
}

$applianceControl = Invoke-ChildScript -Name "appliance-control-plane" -ScriptPath (Join-Path $PSScriptRoot "appliance-control-plane-smoke-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $applianceControl.Values -Key "APPLIANCE_UPDATE_BLOCKED_STATUS" -Expected "failed" -Context $applianceControl.Name
Require-Equal -Map $applianceControl.Values -Key "APPLIANCE_UPDATE_ALLOWED_STATUS" -Expected "completed" -Context $applianceControl.Name
Require-Equal -Map $applianceControl.Values -Key "APPLIANCE_ATTEST_VERIFY_VALID" -Expected "True" -Context $applianceControl.Name
Require-Equal -Map $applianceControl.Values -Key "APPLIANCE_ACTIVE_SLOT_AFTER" -Expected "B" -Context $applianceControl.Name

$applianceProfile = Invoke-ChildScript -Name "appliance-minimal-profile" -ScriptPath (Join-Path $PSScriptRoot "appliance-minimal-profile-smoke-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $applianceProfile.Values -Key "APPLIANCE_PROFILE_FINAL_READY" -Expected "True" -Context $applianceProfile.Name
Require-Equal -Map $applianceProfile.Values -Key "APPLIANCE_PROFILE_FINAL_STATUS" -Expected "ready" -Context $applianceProfile.Name
Require-Equal -Map $applianceProfile.Values -Key "APPLIANCE_PROFILE_DOCTOR_CHECK_AFTER" -Expected "pass" -Context $applianceProfile.Name
Require-Equal -Map $applianceProfile.Values -Key "APPLIANCE_PROFILE_MAINT_ACTION_BEFORE" -Expected "True" -Context $applianceProfile.Name
Require-Equal -Map $applianceProfile.Values -Key "APPLIANCE_PROFILE_MAINT_ACTION_AFTER" -Expected "False" -Context $applianceProfile.Name

$applianceRollout = Invoke-ChildScript -Name "appliance-rollout-boundary" -ScriptPath (Join-Path $PSScriptRoot "appliance-rollout-boundary-smoke-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $applianceRollout.Values -Key "APPLIANCE_ROLLOUT_BLOCKED_STATUS" -Expected "failed" -Context $applianceRollout.Name
Require-Equal -Map $applianceRollout.Values -Key "APPLIANCE_ROLLOUT_CANARY_STATUS" -Expected "completed" -Context $applianceRollout.Name
Require-Equal -Map $applianceRollout.Values -Key "APPLIANCE_ROLLOUT_CANARY_CHANNEL" -Expected "canary" -Context $applianceRollout.Name
Require-Equal -Map $applianceRollout.Values -Key "APPLIANCE_ROLLOUT_STABLE_STATUS" -Expected "completed" -Context $applianceRollout.Name
Require-Equal -Map $applianceRollout.Values -Key "APPLIANCE_ROLLOUT_STABLE_CHANNEL" -Expected "stable" -Context $applianceRollout.Name

$applianceRecovery = Invoke-ChildScript -Name "appliance-restart-recovery" -ScriptPath (Join-Path $PSScriptRoot "appliance-restart-recovery-smoke-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $applianceRecovery.Values -Key "APPLIANCE_RECOVERY_VERSION_AFTER" -Expected "edge-next" -Context $applianceRecovery.Name
Require-Equal -Map $applianceRecovery.Values -Key "APPLIANCE_RECOVERY_ROLLBACK_PENDING_AFTER_RESTART" -Expected "True" -Context $applianceRecovery.Name
Require-Equal -Map $applianceRecovery.Values -Key "APPLIANCE_RECOVERY_ROLLBACK_PENDING_SETTLED" -Expected "False" -Context $applianceRecovery.Name

$baremetalSmoke = Invoke-ChildScript -Name "baremetal-smoke" -ScriptPath (Join-Path $PSScriptRoot "baremetal-smoke-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $baremetalSmoke.Values -Key "BAREMETAL_ELF_MAGIC_PRESENT" -Expected "True" -Context $baremetalSmoke.Name
Require-Equal -Map $baremetalSmoke.Values -Key "BAREMETAL_MULTIBOOT2_MAGIC_PRESENT" -Expected "True" -Context $baremetalSmoke.Name
Require-Equal -Map $baremetalSmoke.Values -Key "BAREMETAL_REQUIRED_SYMBOLS_PRESENT" -Expected "True" -Context $baremetalSmoke.Name

$baremetalQemuSmoke = Invoke-ChildScript -Name "baremetal-qemu-smoke" -ScriptPath (Join-Path $PSScriptRoot "baremetal-qemu-smoke-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $baremetalQemuSmoke.Values -Key "BAREMETAL_QEMU_SMOKE" -Expected "pass" -Context $baremetalQemuSmoke.Name

$baremetalRuntime = Invoke-ChildScript -Name "baremetal-qemu-runtime" -ScriptPath (Join-Path $PSScriptRoot "baremetal-qemu-runtime-oc-tick-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $baremetalRuntime.Values -Key "BAREMETAL_QEMU_RUNTIME_HIT_START" -Expected "True" -Context $baremetalRuntime.Name
Require-Equal -Map $baremetalRuntime.Values -Key "BAREMETAL_QEMU_RUNTIME_HIT_OC_TICK" -Expected "True" -Context $baremetalRuntime.Name
Require-Equal -Map $baremetalRuntime.Values -Key "BAREMETAL_QEMU_RUNTIME_PROBE" -Expected "pass" -Context $baremetalRuntime.Name

$baremetalCommandLoop = Invoke-ChildScript -Name "baremetal-qemu-command-loop" -ScriptPath (Join-Path $PSScriptRoot "baremetal-qemu-command-loop-check.ps1") -ForwardSkipBuild:$SkipBuild
Require-Equal -Map $baremetalCommandLoop.Values -Key "BAREMETAL_QEMU_COMMAND_LOOP_PROBE" -Expected "pass" -Context $baremetalCommandLoop.Name
Require-OneOf -Map $baremetalCommandLoop.Values -Key "BAREMETAL_QEMU_COMMAND_LOOP_LAST_RESULT" -Expected @("0", "0.0") -Context $baremetalCommandLoop.Name

Write-Output "FS6_CLOSURE_APPLIANCE_CONTROL=pass"
Write-Output "FS6_CLOSURE_APPLIANCE_PROFILE=pass"
Write-Output "FS6_CLOSURE_APPLIANCE_ROLLOUT=pass"
Write-Output "FS6_CLOSURE_APPLIANCE_RECOVERY=pass"
Write-Output "FS6_CLOSURE_BAREMETAL_SMOKE=pass"
Write-Output "FS6_CLOSURE_BAREMETAL_QEMU_SMOKE=pass"
Write-Output "FS6_CLOSURE_BAREMETAL_RUNTIME=pass"
Write-Output "FS6_CLOSURE_BAREMETAL_COMMAND_LOOP=pass"
Write-Output "FS6_CLOSURE=pass"
