param(
    [string]$Owner = "adybag14-cyber",
    [string]$Repo = "zig",
    [string]$ReleaseTag = "latest-master",
    [string]$GitHubToken = "",
    [string]$OutputJsonPath = "",
    [string]$OutputMarkdownPath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-GitHubToken {
    param([string]$PreferredToken)

    if (-not [string]::IsNullOrWhiteSpace($PreferredToken)) {
        return $PreferredToken
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        return $env:GITHUB_TOKEN
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        return $env:GH_TOKEN
    }
    return ""
}

function Get-GitHubHeaders {
    param([string]$Token)

    $headers = @{
        Accept = "application/vnd.github+json"
        "User-Agent" = "openclaw-zig-port/zig-github-mirror-release-check"
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

    if ($null -eq $Assets) {
        return $null
    }

    return $Assets |
        Where-Object { $_.name -match '^zig-windows-x86_64-.*\.zip$' } |
        Select-Object -First 1
}

function New-MarkdownReport {
    param([pscustomobject]$Report)

    $lines = @(
        "# Zig GitHub Mirror Release Snapshot",
        "",
        "- Repo: ``$($Report.owner)/$($Report.repo)``",
        "- Release tag: ``$($Report.release_tag)``",
        "- Target commit: ``$($Report.target_commitish)``",
        "- Published at: ``$($Report.release_published_at)``",
        "- Prerelease: ``$($Report.prerelease)``",
        "- Immutable release record: ``$($Report.immutable)``",
        "- Asset: ``$($Report.asset_name)``",
        "- Asset digest (sha256): ``$($Report.asset_digest_sha256)``",
        "- Asset size: ``$($Report.asset_size)``",
        "- Release URL: $($Report.release_url)",
        "- Asset URL: $($Report.asset_download_url)",
        "- Checked at: ``$($Report.checked_at_utc)``"
    )

    return ($lines -join "`n") + "`n"
}

$token = Resolve-GitHubToken -PreferredToken $GitHubToken
$releaseUrl = "https://api.github.com/repos/$Owner/$Repo/releases/tags/$ReleaseTag"
$release = Invoke-GitHubJson -Url $releaseUrl -Token $token
$asset = Select-WindowsZipAsset -Assets $release.assets

$assetDigest = ""
if ($asset -and $asset.digest -match '^sha256:(.+)$') {
    $assetDigest = $Matches[1].ToLowerInvariant()
}

$report = [PSCustomObject]@{
    owner = $Owner
    repo = $Repo
    release_tag = $release.tag_name
    release_name = $release.name
    target_commitish = [string]$release.target_commitish
    release_url = $release.html_url
    release_published_at = $release.published_at
    prerelease = [bool]$release.prerelease
    draft = [bool]$release.draft
    immutable = [bool]$release.immutable
    asset_name = if ($asset) { $asset.name } else { "" }
    asset_download_url = if ($asset) { $asset.browser_download_url } else { "" }
    asset_digest_sha256 = $assetDigest
    asset_size = if ($asset) { [int64]$asset.size } else { 0 }
    asset_content_type = if ($asset) { $asset.content_type } else { "" }
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
}

Write-Output "Mirror repo:          $Owner/$Repo"
Write-Output "Mirror release tag:   $($report.release_tag)"
Write-Output "Release target SHA:   $($report.target_commitish)"
Write-Output "Release published:    $($report.release_published_at)"
Write-Output "Windows asset:        $($report.asset_name)"
Write-Output "Asset digest sha256:  $($report.asset_digest_sha256)"
Write-Output "Asset download URL:   $($report.asset_download_url)"
Write-Output "Release URL:          $($report.release_url)"

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputJsonPath -Encoding Ascii
    Write-Output "Mirror release json:  $OutputJsonPath"
}

if (-not [string]::IsNullOrWhiteSpace($OutputMarkdownPath)) {
    New-MarkdownReport -Report $report | Set-Content -Path $OutputMarkdownPath -Encoding Ascii
    Write-Output "Mirror release md:    $OutputMarkdownPath"
}
