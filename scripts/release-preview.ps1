param(
    [Parameter(Mandatory = $true)]
    [string] $Version,
    [string] $Repo = "adybag14-cyber/openclaw-zig-port",
    [string] $ZigExePath = "",
    [switch] $Publish,
    [switch] $IncludeArm64
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Resolve-ZigExecutable {
    param(
        [string]$PreferredPath
    )

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $candidates += $PreferredPath
    }
    if (-not [string]::IsNullOrWhiteSpace($env:OPENCLAW_ZIG_EXE)) {
        $candidates += $env:OPENCLAW_ZIG_EXE
    }

    $windowsDefault = "C:\users\ady\documents\toolchains\zig-master\current\zig.exe"
    $isWindowsHost = $false
    if (($null -ne $IsWindows -and $IsWindows) -or $env:OS -eq "Windows_NT" -or $PSVersionTable.PSEdition -eq "Desktop") {
        $isWindowsHost = $true
    }
    if ($isWindowsHost) {
        $candidates += $windowsDefault
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
            return $candidate
        }
    }

    $zigCmd = Get-Command zig -ErrorAction SilentlyContinue
    if ($zigCmd -and -not [string]::IsNullOrWhiteSpace($zigCmd.Source)) {
        return $zigCmd.Source
    }

    throw "Unable to locate zig executable. Set -ZigExePath or OPENCLAW_ZIG_EXE, or ensure 'zig' is in PATH."
}

$zigExe = Resolve-ZigExecutable -PreferredPath $ZigExePath

Set-Location $repoRoot

$npmPackCheck = Join-Path $repoRoot "scripts\npm-pack-check.ps1"
if (Test-Path $npmPackCheck) {
    & $npmPackCheck
    if (-not $?) {
        throw "npm package dry-run validation failed."
    }
}

$pythonPackCheck = Join-Path $repoRoot "scripts\python-pack-check.ps1"
if (Test-Path $pythonPackCheck) {
    & $pythonPackCheck
    if (-not $?) {
        throw "python package validation failed."
    }
}

function Invoke-ZigChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Args
    )

    & $zigExe @Args
    if ($LASTEXITCODE -ne 0) {
        throw "zig $($Args -join ' ') failed with exit code $LASTEXITCODE"
    }
}

$targets = @(
    @{ Triple = "x86_64-windows"; Label = "x86_64-windows"; Binary = "openclaw-zig.exe"; Required = $true },
    @{ Triple = "x86_64-linux"; Label = "x86_64-linux"; Binary = "openclaw-zig"; Required = $true },
    @{ Triple = "x86_64-macos"; Label = "x86_64-macos"; Binary = "openclaw-zig"; Required = $true }
)

if ($IncludeArm64) {
    $targets += @{ Triple = "aarch64-linux"; Label = "aarch64-linux"; Binary = "openclaw-zig"; Required = $false }
    $targets += @{ Triple = "aarch64-macos"; Label = "aarch64-macos"; Binary = "openclaw-zig"; Required = $false }
}

$releaseRoot = Join-Path $repoRoot ("release\" + $Version)
if (Test-Path $releaseRoot) {
    Remove-Item -Recurse -Force $releaseRoot
}
New-Item -ItemType Directory -Force -Path $releaseRoot | Out-Null

$assets = New-Object System.Collections.Generic.List[string]
$optionalFailures = New-Object System.Collections.Generic.List[string]

$freshnessScript = Join-Path $repoRoot "scripts\zig-codeberg-master-check.ps1"
$freshnessJsonPath = Join-Path $releaseRoot "zig-master-freshness.json"
if (Test-Path $freshnessScript) {
    try {
        & $freshnessScript -ZigExePath $zigExe -OutputJsonPath $freshnessJsonPath
        if ($LASTEXITCODE -eq 0 -and (Test-Path $freshnessJsonPath)) {
            $assets.Add($freshnessJsonPath) | Out-Null
        }
    }
    catch {
        Write-Warning "Zig freshness snapshot failed; continuing local release flow: $($_.Exception.Message)"
    }
}

$mirrorReleaseScript = Join-Path $repoRoot "scripts\zig-github-mirror-release-check.ps1"
$mirrorReleaseJsonPath = Join-Path $releaseRoot "zig-github-mirror-release.json"
$mirrorReleaseMarkdownPath = Join-Path $releaseRoot "zig-github-mirror-release.md"
if (Test-Path $mirrorReleaseScript) {
    try {
        $mirrorArgs = @{
            OutputJsonPath     = $mirrorReleaseJsonPath
            OutputMarkdownPath = $mirrorReleaseMarkdownPath
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            $mirrorArgs.GitHubToken = $env:GITHUB_TOKEN
        }
        & $mirrorReleaseScript @mirrorArgs
        if ($LASTEXITCODE -eq 0) {
            if (Test-Path $mirrorReleaseJsonPath) {
                $assets.Add($mirrorReleaseJsonPath) | Out-Null
            }
            if (Test-Path $mirrorReleaseMarkdownPath) {
                $assets.Add($mirrorReleaseMarkdownPath) | Out-Null
            }
        }
    }
    catch {
        Write-Warning "GitHub mirror release snapshot failed; continuing local release flow: $($_.Exception.Message)"
    }
}

$parityScript = Join-Path $repoRoot "scripts\check-go-method-parity.ps1"
$parityJsonPath = Join-Path $releaseRoot "parity-go-zig.json"
$parityMdPath = Join-Path $releaseRoot "parity-go-zig.md"
if (-not (Test-Path $parityScript)) {
    throw "Parity script not found: $parityScript"
}
try {
    $parityArgs = @{
        OutputJsonPath = $parityJsonPath
        OutputMarkdownPath = $parityMdPath
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        $parityArgs.GitHubToken = $env:GITHUB_TOKEN
    }
    & $parityScript @parityArgs
    if (-not $?) {
        throw "Multi-baseline parity gate failed in release-preview flow."
    }
}
catch {
    throw "Multi-baseline parity gate failed in release-preview flow. $($_.Exception.Message)"
}
$assets.Add($parityJsonPath) | Out-Null
$assets.Add($parityMdPath) | Out-Null

$docsStatusScript = Join-Path $repoRoot "scripts\docs-status-check.ps1"
if (Test-Path $docsStatusScript) {
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            & $docsStatusScript -ParityJsonPath $parityJsonPath -GitHubToken $env:GITHUB_TOKEN
        } else {
            & $docsStatusScript -ParityJsonPath $parityJsonPath
        }
        if (-not $?) {
            throw "docs status drift gate failed."
        }
    }
    catch {
        throw "Docs status drift gate failed in release-preview flow. $($_.Exception.Message)"
    }
}

$packageRegistryStatusScript = Join-Path $repoRoot "scripts\package-registry-status.ps1"
$packageRegistryStatusPath = Join-Path $releaseRoot "package-registry-status.json"
if (Test-Path $packageRegistryStatusScript) {
    try {
        $packageRegistryArgs = @{
            Repository     = $Repo
            ReleaseTag     = $Version
            NpmPackageName = "@adybag14-cyber/openclaw-zig-rpc-client"
            PythonPackageName = "openclaw-zig-rpc-client"
            OutputJsonPath = $packageRegistryStatusPath
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            $packageRegistryArgs.GitHubToken = $env:GITHUB_TOKEN
        }
        & $packageRegistryStatusScript @packageRegistryArgs
        if (-not $?) {
            throw "package registry preflight failed."
        }
        if (Test-Path $packageRegistryStatusPath) {
            $assets.Add($packageRegistryStatusPath) | Out-Null
        }
    }
    catch {
        throw "Package registry preflight failed in release-preview flow. $($_.Exception.Message)"
    }
}

$releaseStatusScript = Join-Path $repoRoot "scripts\release-status.ps1"
$releaseStatusJsonPath = Join-Path $releaseRoot "release-status.json"
$releaseStatusMarkdownPath = Join-Path $releaseRoot "release-status.md"
if (Test-Path $releaseStatusScript) {
    try {
        $releaseStatusArgs = @{
            Repository                = $Repo
            ReleaseTag                = $Version
            NpmPackageName            = "@adybag14-cyber/openclaw-zig-rpc-client"
            PythonPackageName         = "openclaw-zig-rpc-client"
            PackageRegistryStatusPath = $packageRegistryStatusPath
            OutputJsonPath            = $releaseStatusJsonPath
            OutputMarkdownPath        = $releaseStatusMarkdownPath
        }
        if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
            $releaseStatusArgs.GitHubToken = $env:GITHUB_TOKEN
        }
        & $releaseStatusScript @releaseStatusArgs
        if (-not $?) {
            throw "release status snapshot failed."
        }
        if (Test-Path $releaseStatusJsonPath) {
            $assets.Add($releaseStatusJsonPath) | Out-Null
        }
        if (Test-Path $releaseStatusMarkdownPath) {
            $assets.Add($releaseStatusMarkdownPath) | Out-Null
        }
    }
    catch {
        throw "Release status snapshot failed in release-preview flow. $($_.Exception.Message)"
    }
}

foreach ($target in $targets) {
    Write-Output "Building target: $($target.Triple)"
    try {
        Invoke-ZigChecked -Args @("build", "-Dtarget=$($target.Triple)", "-Doptimize=ReleaseFast", "--summary", "all")
    }
    catch {
        if ($target.Required) {
            throw
        }
        Write-Warning "Optional target failed: $($target.Triple) ($($_.Exception.Message))"
        $optionalFailures.Add($target.Triple) | Out-Null
        continue
    }

    $stageDir = Join-Path $releaseRoot ("openclaw-zig-" + $target.Label)
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

    $binarySource = Join-Path $repoRoot ("zig-out\bin\" + $target.Binary)
    if (-not (Test-Path $binarySource)) {
        throw "Expected build output missing: $binarySource"
    }

    Copy-Item -Force $binarySource (Join-Path $stageDir $target.Binary)
    Copy-Item -Force (Join-Path $repoRoot "README.md") (Join-Path $stageDir "README.md")

    $zipName = "openclaw-zig-$Version-$($target.Label).zip"
    $zipPath = Join-Path $releaseRoot $zipName
    Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $zipPath -Force
    $assets.Add($zipPath) | Out-Null
}

Write-Output "Building bare-metal target: x86_64-freestanding-none"
Invoke-ZigChecked -Args @("build", "baremetal", "-Doptimize=ReleaseFast", "--summary", "all")
$baremetalSource = Join-Path $repoRoot "zig-out\bin\openclaw-zig-baremetal.elf"
if (-not (Test-Path $baremetalSource)) {
    throw "Expected bare-metal build output missing: $baremetalSource"
}
$baremetalAssetName = "openclaw-zig-$Version-x86_64-freestanding-none.elf"
$baremetalAssetPath = Join-Path $releaseRoot $baremetalAssetName
Copy-Item -Force $baremetalSource $baremetalAssetPath
$assets.Add($baremetalAssetPath) | Out-Null

if ($assets.Count -eq 0) {
    throw "No release assets were produced."
}

$checksumPath = Join-Path $releaseRoot "SHA256SUMS.txt"
$checksumLines = $assets | ForEach-Object {
    $hash = Get-FileHash $_ -Algorithm SHA256
    "$($hash.Hash.ToLower())  $(Split-Path $_ -Leaf)"
}
Set-Content -Path $checksumPath -Value $checksumLines -Encoding utf8
$assets.Add($checksumPath) | Out-Null

$releaseEvidenceScript = Join-Path $repoRoot "scripts\generate-release-evidence.ps1"
if (-not (Test-Path $releaseEvidenceScript)) {
    throw "Release evidence script not found: $releaseEvidenceScript"
}

& $releaseEvidenceScript -ArtifactDir $releaseRoot -Version $Version -OutputDir $releaseRoot -Repository $Repo
if ($LASTEXITCODE -ne 0) {
    throw "Release evidence generation failed with exit code $LASTEXITCODE"
}

$releaseEvidenceAssets = @(
    (Join-Path $releaseRoot "release-manifest.json"),
    (Join-Path $releaseRoot "sbom.spdx.json"),
    (Join-Path $releaseRoot "provenance.intoto.json")
)
foreach ($evidenceAsset in $releaseEvidenceAssets) {
    if (-not (Test-Path $evidenceAsset)) {
        throw "Expected release evidence output missing: $evidenceAsset"
    }
    $assets.Add($evidenceAsset) | Out-Null
}

if ($Publish) {
    $notesPath = Join-Path $releaseRoot "RELEASE_NOTES.txt"
    $notes = @(
        "OpenClaw Zig preview release."
        ""
        "Included artifacts:"
    )
    foreach ($asset in $assets) {
        $notes += "- $(Split-Path $asset -Leaf)"
    }
    if ($optionalFailures.Count -gt 0) {
        $notes += ""
        $notes += "Optional targets skipped due to local toolchain failures:"
        foreach ($failed in $optionalFailures) {
            $notes += "- $failed"
        }
    }
    Set-Content -Path $notesPath -Value $notes -Encoding utf8

    $ghArgs = New-Object System.Collections.Generic.List[string]
    $ghArgs.Add("release") | Out-Null
    $ghArgs.Add("create") | Out-Null
    $ghArgs.Add($Version) | Out-Null
    foreach ($asset in $assets) {
        $ghArgs.Add($asset) | Out-Null
    }
    $ghArgs.Add("-R") | Out-Null
    $ghArgs.Add($Repo) | Out-Null
    $ghArgs.Add("--title") | Out-Null
    $ghArgs.Add($Version) | Out-Null
    $ghArgs.Add("--notes-file") | Out-Null
    $ghArgs.Add($notesPath) | Out-Null

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed with exit code $LASTEXITCODE"
    }
}

Write-Output ""
Write-Output "Release bundle ready: $releaseRoot"
Write-Output "Assets:"
foreach ($asset in $assets) {
    Write-Output ("- " + (Split-Path $asset -Leaf))
}
if ($optionalFailures.Count -gt 0) {
    Write-Warning ("Optional targets failed: " + ($optionalFailures -join ", "))
}
