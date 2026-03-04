param(
    [string] $ZigExe = "C:\users\ady\documents\toolchains\zig-master\current\zig.exe",
    [string[]] $Targets = @(
        "x86_64-windows",
        "x86_64-linux",
        "x86_64-macos",
        "aarch64-linux",
        "aarch64-macos",
        "x86_64-linux-android",
        "aarch64-linux-android",
        "arm-linux-androideabi"
    ),
    [string] $LogDir = "",
    [switch] $SkipMinimalRepro,
    [switch] $FailOnFailure
)

$ErrorActionPreference = "Stop"
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not (Test-Path $ZigExe)) {
    throw "Zig executable not found at $ZigExe"
}

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = Join-Path $repoRoot "release\cross-target-diagnostics"
}
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

$tmpDir = Join-Path $repoRoot ".zig-cache\cross-target-diagnostics"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$minimalSource = Join-Path $tmpDir "minimal-main.zig"
Set-Content -Path $minimalSource -Value @'
const std = @import("std");
pub fn main() void {
    _ = std.mem.zeroes(u8);
}
'@ -Encoding utf8

function Invoke-LoggedProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Tag,
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments
    )

    $stdout = Join-Path $LogDir ($Tag + ".stdout.log")
    $stderr = Join-Path $LogDir ($Tag + ".stderr.log")
    $proc = Start-Process -FilePath $ZigExe -ArgumentList $Arguments -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow -Wait -PassThru
    return [ordered]@{
        exitCode = $proc.ExitCode
        stdout = $stdout
        stderr = $stderr
        args = $Arguments -join " "
    }
}

Write-Output "Using Zig: $ZigExe"
& $ZigExe version

$results = New-Object System.Collections.Generic.List[object]

foreach ($target in $Targets) {
    Write-Output ""
    Write-Output ("=== target " + $target + " ===")

    $buildTag = "build-" + $target
    $build = Invoke-LoggedProcess -Tag $buildTag -Arguments @(
        "build",
        "-Dtarget=$target",
        "-Doptimize=ReleaseFast",
        "--summary",
        "all"
    )

    $entry = [ordered]@{
        target = $target
        buildExitCode = [int]$build.exitCode
        buildStdout = $build.stdout
        buildStderr = $build.stderr
        buildArgs = $build.args
        minimalExitCode = $null
        minimalStdout = $null
        minimalStderr = $null
        status = if ($build.exitCode -eq 0) { "ok" } else { "failed" }
    }

    if ($build.exitCode -ne 0 -and -not $SkipMinimalRepro) {
        $emitPath = Join-Path $tmpDir ("minimal-" + $target)
        $minimalTag = "minimal-" + $target
        $minimal = Invoke-LoggedProcess -Tag $minimalTag -Arguments @(
            "build-exe",
            $minimalSource,
            "-target",
            $target,
            "-O",
            "ReleaseFast",
            "-femit-bin=$emitPath"
        )
        $entry.minimalExitCode = [int]$minimal.exitCode
        $entry.minimalStdout = $minimal.stdout
        $entry.minimalStderr = $minimal.stderr
    }

    $results.Add([pscustomobject]$entry) | Out-Null
    Write-Output ("build_exit=" + $entry.buildExitCode + " status=" + $entry.status)
}

$summaryPath = Join-Path $LogDir "summary.json"
$results | ConvertTo-Json -Depth 6 | Set-Content -Path $summaryPath -Encoding utf8

$failed = @($results | Where-Object { $_.status -ne "ok" })
$ok = @($results | Where-Object { $_.status -eq "ok" })

Write-Output ""
Write-Output ("MATRIX_TOTAL=" + $results.Count)
Write-Output ("MATRIX_OK=" + $ok.Count)
Write-Output ("MATRIX_FAILED=" + $failed.Count)
Write-Output ("MATRIX_SUMMARY_JSON=" + $summaryPath)

if ($failed.Count -gt 0) {
    Write-Output "FAILED_TARGETS_START"
    $failed | ForEach-Object { Write-Output $_.target }
    Write-Output "FAILED_TARGETS_END"
}

if ($FailOnFailure -and $failed.Count -gt 0) {
    throw "Cross-target matrix has failures ($($failed.Count)). See $summaryPath"
}
