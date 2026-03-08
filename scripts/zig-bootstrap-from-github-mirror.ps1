param(
    [string]$Owner = "adybag14-cyber",
    [string]$Repo = "zig",
    [string]$ReleaseTag = "latest-master",
    [string]$UpstreamSha = "",
    [string]$GitHubToken = "",
    [string]$InstallRoot = "C:\Users\Ady\Documents\toolchains\zig-master",
    [string]$CurrentLinkName = "current",
    [string]$OutputJsonPath = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-GitHubToken {
    param([string]$PreferredToken)

    if (-not [string]::IsNullOrWhiteSpace($PreferredToken)) { return $PreferredToken }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) { return $env:GITHUB_TOKEN }
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { return $env:GH_TOKEN }
    return ""
}

function Get-GitHubHeaders {
    param([string]$Token)

    $headers = @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "openclaw-zig-port/zig-bootstrap-from-github-mirror"
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $headers.Authorization = "Bearer $Token"
    }
    return $headers
}

function Invoke-GitHubJson {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Token = ""
    )

    return Invoke-RestMethod -Uri $Url -Headers (Get-GitHubHeaders -Token $Token) -Method Get
}

function Select-WindowsZipAsset {
    param([object[]]$Assets)

    if ($null -eq $Assets) { return $null }

    return $Assets |
        Where-Object { $_.name -match '^zig-windows-x86_64-.*\.zip$' } |
        Select-Object -First 1
}

function Write-InstallReport {
    param([pscustomobject]$Report)

    Write-Output "Mirror repo:          $($Report.owner)/$($Report.repo)"
    Write-Output "Release tag:          $($Report.release_tag)"
    Write-Output "Target commit:        $($Report.target_commitish)"
    Write-Output "Asset name:           $($Report.asset_name)"
    Write-Output "Asset digest sha256:  $($Report.asset_digest_sha256)"
    Write-Output "Install root:         $($Report.install_root)"
    Write-Output "Install dir:          $($Report.install_dir)"
    Write-Output "Current link:         $($Report.current_link)"
    Write-Output "Dry run:              $($Report.dry_run)"
    if ($Report.download_url) {
        Write-Output "Download URL:         $($Report.download_url)"
    }
}

function Set-AtomicJunction {
    param(
        [Parameter(Mandatory = $true)][string]$LinkPath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    $nextPath = "$LinkPath.next"
    $previousPath = "$LinkPath.prev"

    foreach ($path in @($nextPath, $previousPath)) {
        if (Test-Path $path) {
            Remove-Item -LiteralPath $path -Force -Recurse
        }
    }

    New-Item -ItemType Junction -Path $nextPath -Target $TargetPath | Out-Null

    if (Test-Path $LinkPath) {
        Move-Item -LiteralPath $LinkPath -Destination $previousPath -Force
    }

    Move-Item -LiteralPath $nextPath -Destination $LinkPath -Force

    if (Test-Path $previousPath) {
        Remove-Item -LiteralPath $previousPath -Force -Recurse
    }
}

$token = Resolve-GitHubToken -PreferredToken $GitHubToken
if (-not [string]::IsNullOrWhiteSpace($UpstreamSha)) {
    $normalizedSha = $UpstreamSha.Trim().ToLowerInvariant()
    if ($normalizedSha -notmatch '^[0-9a-f]{12,40}$') {
        throw "UpstreamSha must be 12-40 hex characters."
    }
    $ReleaseTag = "upstream-" + $normalizedSha.Substring(0, 12)
}

$release = Invoke-GitHubJson -Url "https://api.github.com/repos/$Owner/$Repo/releases/tags/$ReleaseTag" -Token $token
$asset = Select-WindowsZipAsset -Assets $release.assets
if ($null -eq $asset) {
    throw "Could not find a zig-windows-x86_64 zip asset on release tag $ReleaseTag."
}

$assetDigest = ""
if ($asset.digest -match '^sha256:(.+)$') {
    $assetDigest = $Matches[1].ToLowerInvariant()
}

$targetCommitish = ([string]$release.target_commitish).ToLowerInvariant()
$shortSha = if ($targetCommitish.Length -ge 12) { $targetCommitish.Substring(0, 12) } else { $ReleaseTag }
$installDir = Join-Path $InstallRoot ("upstream-" + $shortSha)
$currentLink = Join-Path $InstallRoot $CurrentLinkName

$report = [PSCustomObject]@{
    owner = $Owner
    repo = $Repo
    release_tag = $release.tag_name
    release_name = $release.name
    target_commitish = $targetCommitish
    release_url = $release.html_url
    release_published_at = $release.published_at
    asset_name = $asset.name
    asset_digest_sha256 = $assetDigest
    download_url = $asset.browser_download_url
    install_root = $InstallRoot
    install_dir = $installDir
    current_link = $currentLink
    dry_run = [bool]$DryRun
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
}

Write-InstallReport -Report $report

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputJsonPath -Encoding Ascii
    Write-Output "Bootstrap report json: $OutputJsonPath"
}

if ($DryRun) {
    Write-Output "Bootstrap action:     dry-run only"
    return
}

if ($env:OS -ne "Windows_NT") {
    throw "This bootstrap script currently supports Windows installs only. Use -DryRun on non-Windows hosts."
}

New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
if (-not (Test-Path $installDir)) {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zig-mirror-" + [Guid]::NewGuid().ToString("n"))
    $downloadPath = Join-Path $tempRoot $asset.name
    $expandDir = Join-Path $tempRoot "expanded"

    try {
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
        New-Item -ItemType Directory -Force -Path $expandDir | Out-Null

        Invoke-WebRequest -Uri $asset.browser_download_url -Headers (Get-GitHubHeaders -Token $token) -OutFile $downloadPath

        if (-not [string]::IsNullOrWhiteSpace($assetDigest)) {
            $downloadHash = (Get-FileHash -Path $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($downloadHash -ne $assetDigest) {
                throw "Downloaded asset digest mismatch. Expected $assetDigest, got $downloadHash."
            }
        }

        Expand-Archive -Path $downloadPath -DestinationPath $expandDir -Force
        $zigBinary = Get-ChildItem -Path $expandDir -Recurse -Filter zig.exe | Select-Object -First 1
        if ($null -eq $zigBinary) {
            throw "Expanded archive does not contain zig.exe."
        }

        $sourceRoot = $zigBinary.Directory.FullName
        if (-not (Test-Path (Join-Path $sourceRoot "lib"))) {
            throw "Expanded archive root does not contain the lib directory."
        }

        Move-Item -LiteralPath $sourceRoot -Destination $installDir
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Force -Recurse
        }
    }
}

$metadataPath = Join-Path $installDir "mirror-release.json"
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $metadataPath -Encoding Ascii
Set-AtomicJunction -LinkPath $currentLink -TargetPath $installDir

Write-Output "Bootstrap action:     installed"
Write-Output "Metadata path:        $metadataPath"
