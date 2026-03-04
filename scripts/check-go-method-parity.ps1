param(
    [string] $GoRegistryPath = "",
    [string] $GoRegistryUrl = "",
    [string] $GoRepo = "adybag14-cyber/openclaw-go-port",
    [string] $GoTag = "",
    [string] $OriginalMethodsPath = "",
    [string] $OriginalMethodsUrl = "",
    [string] $OriginalRepo = "openclaw/openclaw",
    [string] $OriginalRef = "",
    [string] $OriginalMethodsRelativePath = "src/gateway/server-methods-list.ts",
    [string] $ZigRegistryPath = "",
    [string] $OutputJsonPath = "",
    [string] $OutputMarkdownPath = "",
    [switch] $FailOnExtra
)

$ErrorActionPreference = "Stop"
$ApiHeaders = @{ "User-Agent" = "openclaw-zig-port-parity" }

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

function Fetch-Text {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Url
    )

    try {
        return (Invoke-WebRequest -UseBasicParsing -Headers $ApiHeaders -Uri $Url).Content
    }
    catch {
        throw "Failed to fetch URL: $Url`n$($_.Exception.Message)"
    }
}

function Resolve-LatestReleaseTag {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Repo
    )

    $releaseUrl = "https://api.github.com/repos/$Repo/releases/latest"
    try {
        $release = Invoke-RestMethod -Headers $ApiHeaders -Uri $releaseUrl
        if ($null -ne $release -and -not [string]::IsNullOrWhiteSpace($release.tag_name)) {
            return [string] $release.tag_name
        }
    }
    catch {
        Write-Warning "Failed to resolve latest release for $Repo via ${releaseUrl}: $($_.Exception.Message)"
    }

    $tagsUrl = "https://api.github.com/repos/$Repo/tags?per_page=1"
    try {
        $tags = Invoke-RestMethod -Headers $ApiHeaders -Uri $tagsUrl
        if ($null -ne $tags -and $tags.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($tags[0].name)) {
            return [string] $tags[0].name
        }
    }
    catch {
        throw "Failed to resolve tags for $Repo via $tagsUrl`n$($_.Exception.Message)"
    }

    throw "Could not resolve latest release/tag for repository: $Repo"
}

function Resolve-GoRegistry {
    param(
        [string] $Path,
        [string] $Url,
        [string] $Repo,
        [string] $Tag
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{
            source = Read-ContentChecked -Path $Path
            origin = "path"
            path = $Path
            url = $null
            repo = $null
            ref = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $resolvedTag = if ([string]::IsNullOrWhiteSpace($Tag)) { Resolve-LatestReleaseTag -Repo $Repo } else { $Tag }
        $Url = "https://raw.githubusercontent.com/$Repo/$resolvedTag/go-agent/internal/rpc/registry.go"
        $Tag = $resolvedTag
    }

    return [ordered]@{
        source = Fetch-Text -Url $Url
        origin = if ([string]::IsNullOrWhiteSpace($Tag)) { "url" } else { "latest_release" }
        path = $null
        url = $Url
        repo = if ([string]::IsNullOrWhiteSpace($Tag)) { $null } else { $Repo }
        ref = $Tag
    }
}

function Resolve-OriginalMethods {
    param(
        [string] $Path,
        [string] $Url,
        [string] $Repo,
        [string] $Ref,
        [string] $RelativePath
    )

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{
            source = Read-ContentChecked -Path $Path
            origin = "path"
            path = $Path
            url = $null
            repo = $null
            ref = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($Url)) {
        $resolvedRef = if ([string]::IsNullOrWhiteSpace($Ref)) { Resolve-LatestReleaseTag -Repo $Repo } else { $Ref }
        $Url = "https://raw.githubusercontent.com/$Repo/$resolvedRef/$RelativePath"
        $Ref = $resolvedRef
    }

    return [ordered]@{
        source = Fetch-Text -Url $Url
        origin = if ([string]::IsNullOrWhiteSpace($Ref)) { "url" } else { "latest_release_or_ref" }
        path = $null
        url = $Url
        repo = if ([string]::IsNullOrWhiteSpace($Ref)) { $null } else { $Repo }
        ref = $Ref
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

function Extract-OriginalMethods {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Source
    )

    $pattern = "const\s+BASE_METHODS\s*=\s*\[(?<body>[\s\S]*?)\n\];"
    $match = [regex]::Match($Source, $pattern)
    if (-not $match.Success) {
        throw "Could not locate BASE_METHODS block in original OpenClaw source."
    }

    $methods = @()
    foreach ($m in [regex]::Matches($match.Groups["body"].Value, '"([^"]+)"')) {
        $methods += $m.Groups[1].Value.Trim().ToLowerInvariant()
    }

    if ($methods.Count -eq 0) {
        throw "Extracted zero methods from original OpenClaw source."
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

function New-MethodSet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Methods
    )

    $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($m in $Methods) {
        [void] $set.Add($m)
    }
    return $set
}

function Compare-BaselineToZig {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $BaselineMethods,
        [Parameter(Mandatory = $true)]
        [string[]] $ZigMethods
    )

    $baselineSet = New-MethodSet -Methods $BaselineMethods
    $zigSet = New-MethodSet -Methods $ZigMethods

    $missingInZig = New-Object System.Collections.Generic.List[string]
    foreach ($m in $BaselineMethods) {
        if (-not $zigSet.Contains($m)) {
            $missingInZig.Add($m) | Out-Null
        }
    }

    $extraInZig = New-Object System.Collections.Generic.List[string]
    foreach ($m in $ZigMethods) {
        if (-not $baselineSet.Contains($m)) {
            $extraInZig.Add($m) | Out-Null
        }
    }

    return [ordered]@{
        missingInZig = @($missingInZig | Sort-Object)
        extraInZig = @($extraInZig | Sort-Object)
    }
}

$goRegistry = Resolve-GoRegistry -Path $GoRegistryPath -Url $GoRegistryUrl -Repo $GoRepo -Tag $GoTag
$originalMethods = Resolve-OriginalMethods -Path $OriginalMethodsPath -Url $OriginalMethodsUrl -Repo $OriginalRepo -Ref $OriginalRef -RelativePath $OriginalMethodsRelativePath
$zigSource = Read-ContentChecked -Path $ZigRegistryPath

$goMethods = Extract-GoMethods -Source $goRegistry.source
$originalMethodSet = Extract-OriginalMethods -Source $originalMethods.source
$zigMethods = Extract-ZigMethods -Source $zigSource

$goVsZig = Compare-BaselineToZig -BaselineMethods $goMethods -ZigMethods $zigMethods
$originalVsZig = Compare-BaselineToZig -BaselineMethods $originalMethodSet -ZigMethods $zigMethods

$unionBaselineMethods = @($goMethods + $originalMethodSet | Sort-Object -Unique)
$unionVsZig = Compare-BaselineToZig -BaselineMethods $unionBaselineMethods -ZigMethods $zigMethods

$report = [ordered]@{
    baseline = [ordered]@{
        go = [ordered]@{
            origin = $goRegistry.origin
            path = $goRegistry.path
            url = $goRegistry.url
            repo = $goRegistry.repo
            ref = $goRegistry.ref
        }
        original = [ordered]@{
            origin = $originalMethods.origin
            path = $originalMethods.path
            url = $originalMethods.url
            repo = $originalMethods.repo
            ref = $originalMethods.ref
            relativePath = $OriginalMethodsRelativePath
        }
        zig = [ordered]@{
            path = $ZigRegistryPath
        }
    }
    counts = [ordered]@{
        go = $goMethods.Count
        original = $originalMethodSet.Count
        union = $unionBaselineMethods.Count
        zig = $zigMethods.Count
        goMissingInZig = $goVsZig.missingInZig.Count
        originalMissingInZig = $originalVsZig.missingInZig.Count
        unionMissingInZig = $unionVsZig.missingInZig.Count
        goExtraInZig = $goVsZig.extraInZig.Count
        originalExtraInZig = $originalVsZig.extraInZig.Count
        unionExtraInZig = $unionVsZig.extraInZig.Count
    }
    methods = [ordered]@{
        missingInZig = [ordered]@{
            go = $goVsZig.missingInZig
            original = $originalVsZig.missingInZig
            union = $unionVsZig.missingInZig
        }
        extraInZig = [ordered]@{
            go = $goVsZig.extraInZig
            original = $originalVsZig.extraInZig
            union = $unionVsZig.extraInZig
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($goRegistry.ref)) {
    Write-Output "GO_BASELINE_REF=$($goRegistry.ref)"
}
if (-not [string]::IsNullOrWhiteSpace($originalMethods.ref)) {
    Write-Output "ORIGINAL_BASELINE_REF=$($originalMethods.ref)"
}
Write-Output "GO_COUNT=$($goMethods.Count)"
Write-Output "ORIGINAL_COUNT=$($originalMethodSet.Count)"
Write-Output "UNION_BASELINE_COUNT=$($unionBaselineMethods.Count)"
Write-Output "ZIG_COUNT=$($zigMethods.Count)"

# Backward-compatible names for existing automation map to Go baseline.
Write-Output "MISSING_IN_ZIG=$($goVsZig.missingInZig.Count)"
Write-Output "EXTRA_IN_ZIG=$($goVsZig.extraInZig.Count)"

Write-Output "GO_MISSING_IN_ZIG=$($goVsZig.missingInZig.Count)"
if ($goVsZig.missingInZig.Count -gt 0) {
    Write-Output "GO_MISSING_METHODS_START"
    $goVsZig.missingInZig | Sort-Object | ForEach-Object { Write-Output $_ }
    Write-Output "GO_MISSING_METHODS_END"
}
Write-Output "GO_EXTRA_IN_ZIG=$($goVsZig.extraInZig.Count)"
if ($goVsZig.extraInZig.Count -gt 0) {
    Write-Output "GO_EXTRA_METHODS_START"
    $goVsZig.extraInZig | Sort-Object | ForEach-Object { Write-Output $_ }
    Write-Output "GO_EXTRA_METHODS_END"
}

Write-Output "ORIGINAL_MISSING_IN_ZIG=$($originalVsZig.missingInZig.Count)"
if ($originalVsZig.missingInZig.Count -gt 0) {
    Write-Output "ORIGINAL_MISSING_METHODS_START"
    $originalVsZig.missingInZig | Sort-Object | ForEach-Object { Write-Output $_ }
    Write-Output "ORIGINAL_MISSING_METHODS_END"
}
Write-Output "ORIGINAL_EXTRA_IN_ZIG=$($originalVsZig.extraInZig.Count)"

Write-Output "UNION_MISSING_IN_ZIG=$($unionVsZig.missingInZig.Count)"
if ($unionVsZig.missingInZig.Count -gt 0) {
    Write-Output "UNION_MISSING_METHODS_START"
    $unionVsZig.missingInZig | Sort-Object | ForEach-Object { Write-Output $_ }
    Write-Output "UNION_MISSING_METHODS_END"
}
Write-Output "UNION_EXTRA_IN_ZIG=$($unionVsZig.extraInZig.Count)"
if ($unionVsZig.extraInZig.Count -gt 0) {
    Write-Output "UNION_EXTRA_METHODS_START"
    $unionVsZig.extraInZig | Sort-Object | ForEach-Object { Write-Output $_ }
    Write-Output "UNION_EXTRA_METHODS_END"
}

if (-not [string]::IsNullOrWhiteSpace($OutputJsonPath)) {
    $outputDir = Split-Path -Parent $OutputJsonPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }
    $reportJson = $report | ConvertTo-Json -Depth 10
    Set-Content -Path $OutputJsonPath -Value $reportJson -Encoding utf8
    Write-Output "PARITY_REPORT_JSON=$OutputJsonPath"
}

if (-not [string]::IsNullOrWhiteSpace($OutputMarkdownPath)) {
    $outputDir = Split-Path -Parent $OutputMarkdownPath
    if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
        New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    }

    $md = New-Object System.Collections.Generic.List[string]
    $tick = [string] [char] 96
    $md.Add("# Multi-Baseline Method Parity Report") | Out-Null
    $md.Add("") | Out-Null
    $md.Add("Generated: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK')") | Out-Null
    $md.Add("") | Out-Null
    $md.Add("## Baselines") | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($goRegistry.path)) {
        $md.Add("- Go baseline path: $tick$($goRegistry.path)$tick") | Out-Null
    }
    else {
        $md.Add("- Go baseline URL: $tick$($goRegistry.url)$tick") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($goRegistry.ref)) {
        $md.Add("- Go baseline ref: $tick$($goRegistry.ref)$tick") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($originalMethods.path)) {
        $md.Add("- Original baseline path: $tick$($originalMethods.path)$tick") | Out-Null
    }
    else {
        $md.Add("- Original baseline URL: $tick$($originalMethods.url)$tick") | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($originalMethods.ref)) {
        $md.Add("- Original baseline ref: $tick$($originalMethods.ref)$tick") | Out-Null
    }
    $md.Add("- Zig registry path: $tick$ZigRegistryPath$tick") | Out-Null
    $md.Add("") | Out-Null
    $md.Add("## Counts") | Out-Null
    $md.Add("| Metric | Value |") | Out-Null
    $md.Add("| --- | ---: |") | Out-Null
    $md.Add("| Go methods | $($goMethods.Count) |") | Out-Null
    $md.Add("| Original methods | $($originalMethodSet.Count) |") | Out-Null
    $md.Add("| Union baseline methods | $($unionBaselineMethods.Count) |") | Out-Null
    $md.Add("| Zig methods | $($zigMethods.Count) |") | Out-Null
    $md.Add("| Missing in Zig (Go baseline) | $($goVsZig.missingInZig.Count) |") | Out-Null
    $md.Add("| Missing in Zig (Original baseline) | $($originalVsZig.missingInZig.Count) |") | Out-Null
    $md.Add("| Missing in Zig (Union baseline) | $($unionVsZig.missingInZig.Count) |") | Out-Null
    $md.Add("| Extra in Zig (Go baseline) | $($goVsZig.extraInZig.Count) |") | Out-Null
    $md.Add("| Extra in Zig (Original baseline) | $($originalVsZig.extraInZig.Count) |") | Out-Null
    $md.Add("| Extra in Zig (Union baseline) | $($unionVsZig.extraInZig.Count) |") | Out-Null
    $md.Add("") | Out-Null
    $md.Add("## Missing In Zig (Go Baseline)") | Out-Null
    if ($goVsZig.missingInZig.Count -eq 0) {
        $md.Add("- None") | Out-Null
    }
    else {
        foreach ($m in $goVsZig.missingInZig) {
            $md.Add("- $tick$m$tick") | Out-Null
        }
    }
    $md.Add("") | Out-Null
    $md.Add("## Missing In Zig (Original Baseline)") | Out-Null
    if ($originalVsZig.missingInZig.Count -eq 0) {
        $md.Add("- None") | Out-Null
    }
    else {
        foreach ($m in $originalVsZig.missingInZig) {
            $md.Add("- $tick$m$tick") | Out-Null
        }
    }
    $md.Add("") | Out-Null
    $md.Add("## Missing In Zig (Union Baseline)") | Out-Null
    if ($unionVsZig.missingInZig.Count -eq 0) {
        $md.Add("- None") | Out-Null
    }
    else {
        foreach ($m in $unionVsZig.missingInZig) {
            $md.Add("- $tick$m$tick") | Out-Null
        }
    }
    $md.Add("") | Out-Null
    $md.Add("## Extra In Zig (Union Baseline)") | Out-Null
    if ($unionVsZig.extraInZig.Count -eq 0) {
        $md.Add("- None") | Out-Null
    }
    else {
        foreach ($m in $unionVsZig.extraInZig) {
            $md.Add("- $tick$m$tick") | Out-Null
        }
    }

    Set-Content -Path $OutputMarkdownPath -Value $md -Encoding utf8
    Write-Output "PARITY_REPORT_MD=$OutputMarkdownPath"
}

if ($goVsZig.missingInZig.Count -gt 0) {
    throw "Go->Zig parity check failed: missing methods in Zig = $($goVsZig.missingInZig.Count)"
}
if ($originalVsZig.missingInZig.Count -gt 0) {
    throw "Original->Zig parity check failed: missing methods in Zig = $($originalVsZig.missingInZig.Count)"
}

if ($FailOnExtra -and $unionVsZig.extraInZig.Count -gt 0) {
    throw "Union baseline parity check failed: extra methods in Zig = $($unionVsZig.extraInZig.Count)"
}

Write-Output "Go + Original -> Zig parity check passed."
