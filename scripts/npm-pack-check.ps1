param(
    [string] $PackageDir = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($PackageDir)) {
    $PackageDir = Join-Path $repoRoot "npm\openclaw-zig-rpc-client"
}

if (-not (Test-Path -LiteralPath $PackageDir)) {
    throw "npm package directory not found: $PackageDir"
}

npm --version | Out-Null
Push-Location $PackageDir
try {
    npm pack --dry-run
    if ($LASTEXITCODE -ne 0) {
        throw "npm pack dry-run failed for $PackageDir"
    }
}
finally {
    Pop-Location
}

Write-Output "npm pack dry-run passed: $PackageDir"
