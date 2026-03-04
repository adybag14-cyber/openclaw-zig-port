param(
    [Parameter(Mandatory = $true)]
    [string] $Version,
    [string] $Repo = "adybag14-cyber/openclaw-zig-port",
    [switch] $Publish,
    [switch] $IncludeArm64
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$zigExe = "C:\users\ady\documents\toolchains\zig-master\current\zig.exe"

if (-not (Test-Path $zigExe)) {
    throw "Zig master executable not found at $zigExe"
}

Set-Location $repoRoot

$npmPackCheck = Join-Path $repoRoot "scripts\npm-pack-check.ps1"
if (Test-Path $npmPackCheck) {
    & $npmPackCheck
    if (-not $?) {
        throw "npm package dry-run validation failed."
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
        throw "Go->Zig parity gate failed in release-preview flow."
    }
}
catch {
    throw "Go->Zig parity gate failed in release-preview flow. $($_.Exception.Message)"
}
$assets.Add($parityJsonPath) | Out-Null
$assets.Add($parityMdPath) | Out-Null

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
