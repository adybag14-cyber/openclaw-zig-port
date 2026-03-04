$ErrorActionPreference = "Stop"

$zigExe = "C:\users\ady\documents\toolchains\zig-master\current\zig.exe"
if (-not (Test-Path $zigExe)) {
    throw "Zig master executable not found at $zigExe"
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
    if ($hash -notmatch "^[0-9a-f]{40}$") {
        return $null
    }
    return [PSCustomObject]@{
        Source = $SourceName
        Hash = $hash
    }
}

$remoteInfo = Get-RemoteMasterHash -RepoUrl "https://codeberg.org/ziglang/zig.git" -SourceName "codeberg"
if (-not $remoteInfo) {
    Write-Warning "Could not fetch Zig master hash from Codeberg. Falling back to GitHub mirror."
    $remoteInfo = Get-RemoteMasterHash -RepoUrl "https://github.com/ziglang/zig.git" -SourceName "github-mirror"
}

$localVersion = (& $zigExe version).Trim()
$localHash = ""
if ($localVersion -match "\+([0-9a-fA-F]+)$") {
    $localHash = $Matches[1].ToLowerInvariant()
}

$isMatch = $false
if (-not [string]::IsNullOrWhiteSpace($localHash) -and $remoteInfo) {
    $isMatch = $remoteInfo.Hash.StartsWith($localHash)
}

if ($remoteInfo) {
    Write-Output "Remote source:        $($remoteInfo.Source)"
    Write-Output "Remote master hash:   $($remoteInfo.Hash)"
} else {
    Write-Warning "Unable to fetch Zig master hash from both Codeberg and GitHub mirror."
    Write-Output "Remote source:        unavailable"
    Write-Output "Remote master hash:   unavailable"
}
Write-Output "Local zig version:    $localVersion"
if ($localHash -ne "") {
    Write-Output "Local zig hash:       $localHash"
}
Write-Output "Hash match:           $isMatch"

if ($remoteInfo -and -not $isMatch) {
    Write-Warning "Local Zig toolchain does not match current $($remoteInfo.Source) Zig master."
}
