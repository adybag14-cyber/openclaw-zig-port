param(
    [string] $RegistryPath = "",
    [string] $OutputPath = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
    $RegistryPath = Join-Path $repoRoot "src\gateway\registry.zig"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot "docs\rpc-reference.md"
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
        $method = $m.Groups[1].Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($method)) {
            $methods += $method
        }
    }

    if ($methods.Count -eq 0) {
        throw "Extracted zero methods from Zig source."
    }

    return $methods | Sort-Object -Unique
}

function Resolve-Prefix {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Method
    )

    $firstDot = $Method.IndexOf(".")
    if ($firstDot -gt 0) {
        return $Method.Substring(0, $firstDot)
    }

    return "(root)"
}

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    throw "Registry file not found: $RegistryPath"
}

$source = Get-Content -Raw -Path $RegistryPath
$methods = Extract-ZigMethods -Source $source

$groups = @{}
foreach ($method in $methods) {
    $prefix = Resolve-Prefix -Method $method
    if (-not $groups.ContainsKey($prefix)) {
        $groups[$prefix] = New-Object System.Collections.Generic.List[string]
    }
    $groups[$prefix].Add($method)
}

$prefixOrder = @()
if ($groups.ContainsKey("(root)")) {
    $prefixOrder += "(root)"
}
$prefixOrder += ($groups.Keys | Where-Object { $_ -ne "(root)" } | Sort-Object)

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# RPC Reference")
$lines.Add("")
$lines.Add('This page is generated from the method registry in `src/gateway/registry.zig`.')
$lines.Add("Regenerate with:")
$lines.Add("")
$lines.Add('```powershell')
$lines.Add("./scripts/generate-rpc-reference.ps1")
$lines.Add('```')
$lines.Add("")
$lines.Add('Source of truth: [`src/gateway/registry.zig`](https://github.com/adybag14-cyber/openclaw-zig-port/blob/main/src/gateway/registry.zig)')
$lines.Add("")
$lines.Add("## Common Envelope")
$lines.Add("")
$lines.Add('```json')
$lines.Add('{')
$lines.Add('  "id": "req-1",')
$lines.Add('  "method": "health",')
$lines.Add('  "params": {}')
$lines.Add('}')
$lines.Add('```')
$lines.Add("")
$lines.Add("## Summary")
$lines.Add("")
$lines.Add("- Total methods: **$($methods.Count)**")
$lines.Add("- Prefix groups: **$($prefixOrder.Count)**")
$lines.Add("")
$lines.Add("## Prefix Overview")
$lines.Add("")
$lines.Add("| Prefix | Count |")
$lines.Add("| --- | ---: |")
foreach ($prefix in $prefixOrder) {
    $lines.Add("| $prefix | $($groups[$prefix].Count) |")
}
$lines.Add("")
$lines.Add("## Method Index")
$lines.Add("")

foreach ($prefix in $prefixOrder) {
    $lines.Add("### $prefix")
    $lines.Add("")
    $groupMethods = $groups[$prefix] | Sort-Object
    foreach ($method in $groupMethods) {
        $lines.Add("- $method")
    }
    $lines.Add("")
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -LiteralPath $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir | Out-Null
}

$content = ($lines -join "`n") + "`n"
Set-Content -Path $OutputPath -Value $content -Encoding utf8NoBOM
Write-Host "Generated RPC reference at $OutputPath ($($methods.Count) methods)."
