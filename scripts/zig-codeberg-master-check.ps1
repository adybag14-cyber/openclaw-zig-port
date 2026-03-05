param(
    [string]$ZigExePath = "",
    [string]$OutputJsonPath = ""
)

$ErrorActionPreference = "Stop"

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

$zigExe = Resolve-ZigExecutable -PreferredPath $ZigExePath

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
Write-Output "Local zig path:       $zigExe"
if ($localHash -ne "") {
    Write-Output "Local zig hash:       $localHash"
}
Write-Output "Hash match:           $isMatch"

$report = [PSCustomObject]@{
    remote_source = if ($remoteInfo) { $remoteInfo.Source } else { "unavailable" }
    remote_master_hash = if ($remoteInfo) { $remoteInfo.Hash } else { "" }
    local_zig_path = $zigExe
    local_zig_version = $localVersion
    local_zig_hash = $localHash
    hash_match = $isMatch
    checked_at_utc = [DateTime]::UtcNow.ToString("o")
}

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputJsonPath
    Write-Output "Freshness report json: $OutputJsonPath"
}

if ($remoteInfo -and -not $isMatch) {
    Write-Warning "Local Zig toolchain does not match current $($remoteInfo.Source) Zig master."
}
