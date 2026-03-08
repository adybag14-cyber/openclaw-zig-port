param(
    [string]$ZigExePath = "",
    [string]$GitHubToken = "",
    [string]$MirrorOwner = "adybag14-cyber",
    [string]$MirrorRepo = "zig",
    [string]$MirrorReleaseTag = "latest-master",
    [string]$OutputJsonPath = "",
    [string]$OutputMarkdownPath = ""
)

$ErrorActionPreference = "Stop"

function Resolve-ZigExecutable {
    param([string]$PreferredPath)

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
        "User-Agent" = "openclaw-zig-port/zig-codeberg-master-check"
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

function Get-RemoteMasterHash {
    param(
        [Parameter(Mandatory = $true)][string]$RepoUrl,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    $nativePref = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($nativePref) {
        $previousNativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $remote = & git ls-remote $RepoUrl refs/heads/master 2>$null
    }
    catch {
        return $null
    }
    finally {
        if ($nativePref) {
            $PSNativeCommandUseErrorActionPreference = $previousNativePref
        }
    }

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remote)) {
        return $null
    }

    $hash = ($remote -split "\s+")[0].Trim().ToLowerInvariant()
    if ($hash -notmatch '^[0-9a-f]{40}$') {
        return $null
    }

    return [PSCustomObject]@{
        Source = $SourceName
        Hash = $hash
    }
}

function Get-GitHubMirrorReleaseInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Owner,
        [Parameter(Mandatory = $true)][string]$Repo,
        [Parameter(Mandatory = $true)][string]$ReleaseTag,
        [string]$Token = ""
    )

    try {
        $release = Invoke-GitHubJson -Url "https://api.github.com/repos/$Owner/$Repo/releases/tags/$ReleaseTag" -Token $Token
    }
    catch {
        return $null
    }

    $asset = $null
    if ($release.assets) {
        $asset = $release.assets |
            Where-Object { $_.name -match '^zig-windows-x86_64-.*\.zip$' } |
            Select-Object -First 1
    }

    $digest = ""
    if ($asset -and $asset.digest -match '^sha256:(.+)$') {
        $digest = $Matches[1].ToLowerInvariant()
    }

    return [PSCustomObject]@{
        Owner = $Owner
        Repo = $Repo
        ReleaseTag = $release.tag_name
        ReleaseName = $release.name
        TargetCommitish = ([string]$release.target_commitish).ToLowerInvariant()
        ReleaseUrl = $release.html_url
        ReleasePublishedAt = $release.published_at
        Immutable = [bool]$release.immutable
        Prerelease = [bool]$release.prerelease
        AssetName = if ($asset) { $asset.name } else { "" }
        AssetDownloadUrl = if ($asset) { $asset.browser_download_url } else { "" }
        AssetDigestSha256 = $digest
        AssetSize = if ($asset) { [int64]$asset.size } else { 0 }
    }
}

function New-MarkdownReport {
    param([pscustomobject]$Report)

    $lines = @(
        "# Zig Master Freshness Snapshot",
        "",
        "- Remote source: ``$($Report.remote_source)``",
        "- Remote master hash: ``$($Report.remote_master_hash)``",
        "- Local Zig version: ``$($Report.local_zig_version)``",
        "- Local Zig hash: ``$($Report.local_zig_hash)``",
        "- Local matches remote: ``$($Report.hash_match)``",
        "- GitHub mirror repo: ``$($Report.github_mirror_repo)``",
        "- Mirror release tag: ``$($Report.github_mirror_release_tag)``",
        "- Mirror target commit: ``$($Report.github_mirror_target_commitish)``",
        "- Mirror matches remote: ``$($Report.github_mirror_matches_remote)``",
        "- Local matches mirror target: ``$($Report.local_matches_github_mirror_release)``",
        "- Mirror asset: ``$($Report.github_mirror_asset_name)``",
        "- Mirror asset digest: ``$($Report.github_mirror_asset_digest_sha256)``",
        "- Mirror asset URL: $($Report.github_mirror_asset_download_url)",
        "- Checked at: ``$($Report.checked_at_utc)``"
    )

    return ($lines -join "`n") + "`n"
}

$zigExe = Resolve-ZigExecutable -PreferredPath $ZigExePath
$token = Resolve-GitHubToken -PreferredToken $GitHubToken

$remoteInfo = Get-RemoteMasterHash -RepoUrl "https://codeberg.org/ziglang/zig.git" -SourceName "codeberg"
if (-not $remoteInfo) {
    Write-Warning "Could not fetch Zig master hash from Codeberg. Falling back to GitHub mirror."
    $remoteInfo = Get-RemoteMasterHash -RepoUrl "https://github.com/ziglang/zig.git" -SourceName "github-mirror"
}

$localVersion = (& $zigExe version).Trim()
$localHash = ""
if ($localVersion -match '\+([0-9a-fA-F]+)$') {
    $localHash = $Matches[1].ToLowerInvariant()
}

$mirrorInfo = Get-GitHubMirrorReleaseInfo -Owner $MirrorOwner -Repo $MirrorRepo -ReleaseTag $MirrorReleaseTag -Token $token
if (-not $mirrorInfo) {
    Write-Warning "Unable to fetch GitHub mirror release metadata from $MirrorOwner/$MirrorRepo tag $MirrorReleaseTag."
}

$hashMatch = $false
if (-not [string]::IsNullOrWhiteSpace($localHash) -and $remoteInfo) {
    $hashMatch = $remoteInfo.Hash.StartsWith($localHash)
}

$mirrorMatchesRemote = $false
if ($remoteInfo -and $mirrorInfo -and -not [string]::IsNullOrWhiteSpace($mirrorInfo.TargetCommitish)) {
    $mirrorMatchesRemote = ($remoteInfo.Hash -eq $mirrorInfo.TargetCommitish)
}

$localMatchesMirror = $false
if (-not [string]::IsNullOrWhiteSpace($localHash) -and $mirrorInfo -and -not [string]::IsNullOrWhiteSpace($mirrorInfo.TargetCommitish)) {
    $localMatchesMirror = $mirrorInfo.TargetCommitish.StartsWith($localHash)
}

if ($remoteInfo) {
    Write-Output "Remote source:                 $($remoteInfo.Source)"
    Write-Output "Remote master hash:            $($remoteInfo.Hash)"
} else {
    Write-Warning "Unable to fetch Zig master hash from both Codeberg and GitHub mirror."
    Write-Output "Remote source:                 unavailable"
    Write-Output "Remote master hash:            unavailable"
}
Write-Output "Local zig version:             $localVersion"
Write-Output "Local zig path:                $zigExe"
if ($localHash -ne "") {
    Write-Output "Local zig hash:                $localHash"
}
Write-Output "Local matches remote:          $hashMatch"

if ($mirrorInfo) {
    Write-Output "GitHub mirror repo:            $($mirrorInfo.Owner)/$($mirrorInfo.Repo)"
    Write-Output "GitHub mirror release tag:     $($mirrorInfo.ReleaseTag)"
    Write-Output "GitHub mirror target commit:   $($mirrorInfo.TargetCommitish)"
    Write-Output "GitHub mirror matches remote:  $mirrorMatchesRemote"
    Write-Output "Local matches mirror target:   $localMatchesMirror"
    Write-Output "GitHub mirror asset:           $($mirrorInfo.AssetName)"
    Write-Output "GitHub mirror asset digest:    $($mirrorInfo.AssetDigestSha256)"
    Write-Output "GitHub mirror asset URL:       $($mirrorInfo.AssetDownloadUrl)"
    Write-Output "GitHub mirror release URL:     $($mirrorInfo.ReleaseUrl)"
}

$report = [PSCustomObject]@{
    remote_source = if ($remoteInfo) { $remoteInfo.Source } else { "unavailable" }
    remote_master_hash = if ($remoteInfo) { $remoteInfo.Hash } else { "" }
    local_zig_path = $zigExe
    local_zig_version = $localVersion
    local_zig_hash = $localHash
    hash_match = $hashMatch
    github_mirror_repo = "$MirrorOwner/$MirrorRepo"
    github_mirror_release_tag = if ($mirrorInfo) { $mirrorInfo.ReleaseTag } else { $MirrorReleaseTag }
    github_mirror_target_commitish = if ($mirrorInfo) { $mirrorInfo.TargetCommitish } else { "" }
    github_mirror_release_url = if ($mirrorInfo) { $mirrorInfo.ReleaseUrl } else { "" }
    github_mirror_release_published_at = if ($mirrorInfo) { $mirrorInfo.ReleasePublishedAt } else { "" }
    github_mirror_prerelease = if ($mirrorInfo) { [bool]$mirrorInfo.Prerelease } else { $false }
    github_mirror_immutable = if ($mirrorInfo) { [bool]$mirrorInfo.Immutable } else { $false }
    github_mirror_matches_remote = $mirrorMatchesRemote
    local_matches_github_mirror_release = $localMatchesMirror
    github_mirror_asset_name = if ($mirrorInfo) { $mirrorInfo.AssetName } else { "" }
    github_mirror_asset_download_url = if ($mirrorInfo) { $mirrorInfo.AssetDownloadUrl } else { "" }
    github_mirror_asset_digest_sha256 = if ($mirrorInfo) { $mirrorInfo.AssetDigestSha256 } else { "" }
    github_mirror_asset_size = if ($mirrorInfo) { [int64]$mirrorInfo.AssetSize } else { 0 }
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
}

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputJsonPath -Encoding Ascii
    Write-Output "Freshness report json:         $OutputJsonPath"
}

if (-not [string]::IsNullOrWhiteSpace($OutputMarkdownPath)) {
    New-MarkdownReport -Report $report | Set-Content -Path $OutputMarkdownPath -Encoding Ascii
    Write-Output "Freshness report markdown:     $OutputMarkdownPath"
}

if ($remoteInfo -and -not $hashMatch) {
    Write-Warning "Local Zig toolchain does not match current $($remoteInfo.Source) Zig master."
}
if ($remoteInfo -and $mirrorInfo -and -not $mirrorMatchesRemote) {
    Write-Warning "GitHub mirror release target does not match current remote master."
}
