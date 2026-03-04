Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true

function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Command
    )

    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Native command failed with exit code $LASTEXITCODE"
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$packageRoot = Join-Path $repoRoot "python/openclaw-zig-rpc-client"
$distDir = Join-Path $packageRoot "dist"

Write-Output "PYTHON_PACKAGE_ROOT=$packageRoot"

Push-Location $packageRoot
try {
    if (Test-Path $distDir) {
        Remove-Item -Recurse -Force $distDir
    }

    Invoke-Native { python -m pip install --upgrade pip }
    Invoke-Native { python -m pip install --upgrade build twine }
    Invoke-Native { python -m pip install -e . }
    Invoke-Native { python -m unittest discover -s tests -p "test_*.py" }
    Invoke-Native { python -m build --sdist --wheel --outdir dist }
    Invoke-Native { python -m twine check dist/* }

    $artifacts = Get-ChildItem -Path $distDir -File
    if ($artifacts.Count -eq 0) {
        throw "No Python build artifacts generated in dist/"
    }

    Write-Output "PYTHON_DIST_COUNT=$($artifacts.Count)"
    foreach ($artifact in $artifacts) {
        Write-Output "PYTHON_DIST_ARTIFACT=$($artifact.Name)"
    }
}
finally {
    Pop-Location
}
