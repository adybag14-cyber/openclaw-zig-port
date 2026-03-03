$ErrorActionPreference = "Stop"

$zigExe = "C:\users\ady\documents\toolchains\zig-master\current\zig.exe"
if (-not (Test-Path $zigExe)) {
    throw "Zig master executable not found at $zigExe"
}

$remote = git ls-remote https://codeberg.org/ziglang/zig.git refs/heads/master
if ([string]::IsNullOrWhiteSpace($remote)) {
    throw "Failed to fetch Codeberg master hash."
}
$remoteHash = ($remote -split "\s+")[0].Trim()

$localVersion = (& $zigExe version).Trim()
$localHash = ""
if ($localVersion -match "\+([0-9a-fA-F]+)$") {
    $localHash = $Matches[1].ToLowerInvariant()
}

$isMatch = $false
if (-not [string]::IsNullOrWhiteSpace($localHash)) {
    $isMatch = $remoteHash.StartsWith($localHash)
}

Write-Output "Codeberg master hash: $remoteHash"
Write-Output "Local zig version:    $localVersion"
if ($localHash -ne "") {
    Write-Output "Local zig hash:       $localHash"
}
Write-Output "Hash match:           $isMatch"

if (-not $isMatch) {
    Write-Warning "Local Zig toolchain does not match current Codeberg master."
}
