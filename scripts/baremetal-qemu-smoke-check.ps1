param(
    [switch] $SkipBuild,
    [int] $TimeoutSeconds = 20
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

function Resolve-QemuExecutable {
    $candidates = @(
        "qemu-system-x86_64",
        "qemu-system-x86_64.exe",
        "C:\Program Files\qemu\qemu-system-x86_64.exe"
    )

    foreach ($name in $candidates) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $cmd -and $cmd.Path) {
            return $cmd.Path
        }
        if (Test-Path $name) {
            return (Resolve-Path $name).Path
        }
    }

    return $null
}

Set-Location $repo
$zig = Resolve-ZigExecutable
$qemu = Resolve-QemuExecutable

if ($null -eq $qemu) {
    Write-Output "BAREMETAL_QEMU_AVAILABLE=False"
    Write-Output "BAREMETAL_QEMU_SMOKE=skipped"
    return
}

$expectedExitCode = 85 # isa-debug-exit returns (code << 1) | 1, where code=0x2A

if (-not $SkipBuild) {
    & $zig build baremetal -Dbaremetal-qemu-smoke=true --summary all
    if ($LASTEXITCODE -ne 0) {
        throw "zig build baremetal -Dbaremetal-qemu-smoke=true failed with exit code $LASTEXITCODE"
    }
}

$artifactCandidates = @(
    (Join-Path $repo "zig-out\bin\openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out/openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out\openclaw-zig-baremetal.elf"),
    (Join-Path $repo "zig-out/bin/openclaw-zig-baremetal.elf")
)

$artifact = $null
foreach ($candidate in $artifactCandidates) {
    if (Test-Path $candidate) {
        $artifact = (Resolve-Path $candidate).Path
        break
    }
}
if ($null -eq $artifact) {
    throw "Bare-metal artifact not found after build."
}

$stdoutPath = Join-Path $repo "release\qemu-smoke-stdout.log"
$stderrPath = Join-Path $repo "release\qemu-smoke-stderr.log"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stdoutPath) | Out-Null
if (Test-Path $stdoutPath) { Remove-Item -Force $stdoutPath }
if (Test-Path $stderrPath) { Remove-Item -Force $stderrPath }

$qemuArgs = @(
    "-kernel", $artifact,
    "-nographic",
    "-no-reboot",
    "-no-shutdown",
    "-serial", "none",
    "-monitor", "none",
    "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04"
)

$proc = Start-Process -FilePath $qemu -ArgumentList $qemuArgs -PassThru -NoNewWindow -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

try {
    $null = Wait-Process -Id $proc.Id -Timeout $TimeoutSeconds -ErrorAction Stop
}
catch {
    try {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    } catch {}
    throw "QEMU bare-metal smoke timed out after $TimeoutSeconds seconds."
}

$exitCode = $proc.ExitCode
if ($exitCode -ne $expectedExitCode) {
    $stderrTail = ""
    if (Test-Path $stderrPath) {
        $stderrTail = (Get-Content -Path $stderrPath -Tail 40 -ErrorAction SilentlyContinue) -join "`n"
    }
    throw "QEMU bare-metal smoke failed: exit=$exitCode expected=$expectedExitCode`n$stderrTail"
}

Write-Output "BAREMETAL_QEMU_AVAILABLE=True"
Write-Output "BAREMETAL_QEMU_BINARY=$qemu"
Write-Output "BAREMETAL_QEMU_ARTIFACT=$artifact"
Write-Output "BAREMETAL_QEMU_EXPECTED_EXIT_CODE=$expectedExitCode"
Write-Output "BAREMETAL_QEMU_EXIT_CODE=$exitCode"
Write-Output "BAREMETAL_QEMU_SMOKE=pass"
