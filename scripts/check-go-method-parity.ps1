param(
    [string] $GoRegistryPath = "",
    [string] $GoRegistryUrl = "https://raw.githubusercontent.com/adybag14-cyber/openclaw-go-port/65c974b528e2a960b171e3110e8e4e4dbb6fda63/go-agent/internal/rpc/registry.go",
    [string] $ZigRegistryPath = "",
    [string] $OutputJsonPath = "",
    [switch] $FailOnExtra
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($ZigRegistryPath)) {
    $ZigRegistryPath = Join-Path $repoRoot "src\gateway\registry.zig"
}

function Read-ContentChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    if (-not (Test-Path $Path)) {
        throw "File not found: $Path"
    }
    return Get-Content -Raw -Path $Path
}

function Read-GoRegistrySource {
    param(
        [string] $Path,
        [string] $Url
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return Read-ContentChecked -Path $Path
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "Either GoRegistryPath or GoRegistryUrl must be provided."
    }

    try {
        return (Invoke-WebRequest -UseBasicParsing -Uri $Url).Content
    }
    catch {
        throw "Failed to fetch Go registry from URL: $Url`n$($_.Exception.Message)"
    }
}

function Extract-GoMethods {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source
    )

    $pattern = "var\s+defaultSupportedRPCMethods\s*=\s*\[\]string\s*\{(?<body>[\s\S]*?)\n\}"
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) {
        throw "Could not locate defaultSupportedRPCMethods block in Go source."
    }

    $methods = @()
    foreach ($m in [regex]::Matches($match.Groups["body"].Value, '"([^"]+)"')) {
        $methods += $m.Groups[1].Value.Trim().ToLowerInvariant()
    }

    if ($methods.Count -eq 0) {
        throw "Extracted zero methods from Go source."
    }

    return $methods | Sort-Object -Unique
}

function Extract-ZigMethods {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source
    )

    $pattern = "pub\s+const\s+supported_methods\s*=\s*\[_\]\[\]const\s+u8\s*\{(?<body>[\s\S]*?)\n\};"
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) {
        throw "Could not locate supported_methods block in Zig source."
    }

    $methods = @()
    foreach ($m in [regex]::Matches($match.Groups["body"].Value, '"([^"]+)"')) {
        $methods += $m.Groups[1].Value.Trim().ToLowerInvariant()
    }

    if ($methods.Count -eq 0) {
        throw "Extracted zero methods from Zig source."
    }

    return $methods | Sort-Object -Unique
}

$goSource = Read-GoRegistrySource -Path $GoRegistryPath -Url $GoRegistryUrl
$zigSource = Read-ContentChecked -Path $ZigRegistryPath

$goMethods = Extract-GoMethods -Source $goSource
$zigMethods = Extract-ZigMethods -Source $zigSource

$goSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$zigSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($m in $goMethods) { [void]$goSet.Add($m) }
foreach ($m in $zigMethods) { [void]$zigSet.Add($m) }

$missingInZig = New-Object System.Collections.Generic.List[string]
foreach ($m in $goMethods) {
    if (-not $zigSet.Contains($m)) { $missingInZig.Add($m) | Out-Null }
}

$extraInZig = New-Object System.Collections.Generic.List[string]
foreach ($m in $zigMethods) {
    if (-not $goSet.Contains($m)) { $extraInZig.Add($m) | Out-Null }
}

$report = [ordered]@{
    baseline = [ordered]@{
        goRegistryPath = if ([string]::IsNullOrWhiteSpace($GoRegistryPath)) { $null } else { $GoRegistryPath }
        goRegistryUrl = if ([string]::IsNullOrWhiteSpace($GoRegistryPath)) { $GoRegistryUrl } else { $null }
        zigRegistryPath = $ZigRegistryPath
    }
    counts = [ordered]@{
        go = $goMethods.Count
        zig = $zigMethods.Count
        missingInZig = $missingInZig.Count
        extraInZig = $extraInZig.Count
    }
    missingInZig = @($missingInZig | Sort-Object)
    extraInZig = @($extraInZig | Sort-Object)
}

Write-Output "GO_COUNT=$($goMethods.Count)"
Write-Output "ZIG_COUNT=$($zigMethods.Count)"
Write-Output "MISSING_IN_ZIG=$($missingInZig.Count)"
if ($missingInZig.Count -gt 0) {
    Write-Output "MISSING_METHODS_START"
    $missingInZig | Sort-Object | ForEach-Object { Write-Output $_ }
    Write-Output "MISSING_METHODS_END"
}
Write-Output "EXTRA_IN_ZIG=$($extraInZig.Count)"
if ($extraInZig.Count -gt 0) {
    Write-Output "EXTRA_METHODS_START"
    $extraInZig | Sort-Object | ForEach-Object { Write-Output $_ }
    Write-Output "EXTRA_METHODS_END"
}

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $outputDir = Split-Path -Parent $OutputJsonPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    $reportJson = $report | ConvertTo-Json -Depth 8
    Set-Content -Path $OutputJsonPath -Value $reportJson -Encoding utf8
    Write-Output "PARITY_REPORT_JSON=$OutputJsonPath"
}

if ($missingInZig.Count -gt 0) {
    throw "Go->Zig parity check failed: missing methods in Zig = $($missingInZig.Count)"
}

if ($FailOnExtra -and $extraInZig.Count -gt 0) {
    throw "Go->Zig parity check failed: extra methods in Zig = $($extraInZig.Count)"
}

Write-Output "Go->Zig parity check passed."
