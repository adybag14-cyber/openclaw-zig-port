param(
    [Parameter(Mandatory = $true)]
    [string] $ArtifactDir,
    [Parameter(Mandatory = $true)]
    [string] $Version,
    [string] $OutputDir,
    [string] $Repository = "",
    [string] $Commit = ""
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ArtifactDir)) {
    throw "Artifact directory does not exist: $ArtifactDir"
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = $ArtifactDir
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($Repository)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
        $Repository = $env:GITHUB_REPOSITORY
    } else {
        $Repository = "local/openclaw-zig-port"
    }
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SHA)) {
        $Commit = $env:GITHUB_SHA
    } else {
        try {
            $repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
            $resolvedCommit = git -C $repoRoot rev-parse HEAD 2>$null
            if (-not [string]::IsNullOrWhiteSpace($resolvedCommit)) {
                $Commit = $resolvedCommit.Trim()
            }
        }
        catch {
            $Commit = ""
        }
    }
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
    $Commit = "unknown"
}

$artifactFiles = Get-ChildItem -LiteralPath $ArtifactDir -File |
    Where-Object { $_.Extension -in @(".zip", ".elf") } |
    Sort-Object Name

if ($artifactFiles.Count -eq 0) {
    throw "No release artifact files found in $ArtifactDir (expected .zip/.elf)"
}

$generatedAt = [DateTime]::UtcNow
$generatedAtIso = $generatedAt.ToString("yyyy-MM-ddTHH:mm:ssZ")
$finishedAtIso = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$escapedVersion = [uri]::EscapeDataString($Version)
$namespaceSuffix = $generatedAt.ToString("yyyyMMddHHmmss")

$subjects = New-Object System.Collections.Generic.List[object]
$manifestArtifacts = New-Object System.Collections.Generic.List[object]
$spdxPackages = New-Object System.Collections.Generic.List[object]
$spdxRelationships = New-Object System.Collections.Generic.List[object]
$provenanceByproducts = New-Object System.Collections.Generic.List[object]

$index = 0
foreach ($artifact in $artifactFiles) {
    $index += 1
    $sha256 = (Get-FileHash -LiteralPath $artifact.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $artifactName = $artifact.Name
    $packageId = "SPDXRef-Package-$index"

    $subjects.Add(@{
            name = $artifactName
            digest = @{
                sha256 = $sha256
            }
        }) | Out-Null

    $manifestArtifacts.Add(@{
            name = $artifactName
            path = $artifactName
            sizeBytes = $artifact.Length
            sha256 = $sha256
        }) | Out-Null

    $spdxPackages.Add(@{
            name = $artifactName
            SPDXID = $packageId
            downloadLocation = "NOASSERTION"
            filesAnalyzed = $false
            versionInfo = $Version
            checksums = @(
                @{
                    algorithm = "SHA256"
                    checksumValue = $sha256
                }
            )
            licenseConcluded = "NOASSERTION"
            licenseDeclared = "NOASSERTION"
            copyrightText = "NOASSERTION"
        }) | Out-Null

    $spdxRelationships.Add(@{
            spdxElementId = "SPDXRef-DOCUMENT"
            relationshipType = "DESCRIBES"
            relatedSpdxElement = $packageId
        }) | Out-Null
}

$defaultByproducts = @(
    "SHA256SUMS.txt",
    "parity-go-zig.json",
    "parity-go-zig.md",
    "zig-master-freshness.json",
    "zig-github-mirror-release.json",
    "zig-github-mirror-release.md",
    "package-registry-status.json",
    "release-status.json",
    "release-status.md"
)
foreach ($byproductName in $defaultByproducts) {
    $byproductPath = Join-Path $ArtifactDir $byproductName
    if (Test-Path -LiteralPath $byproductPath) {
        $provenanceByproducts.Add(@{
                name = $byproductName
                path = $byproductName
            }) | Out-Null
    }
}

$manifest = @{
    schemaVersion = 1
    generatedAt = $generatedAtIso
    releaseVersion = $Version
    repository = $Repository
    commit = $Commit
    artifactCount = $artifactFiles.Count
    artifacts = $manifestArtifacts
}

$sbom = @{
    spdxVersion = "SPDX-2.3"
    dataLicense = "CC0-1.0"
    SPDXID = "SPDXRef-DOCUMENT"
    name = "openclaw-zig-release-$Version-sbom"
    documentNamespace = "https://github.com/$Repository/releases/download/$escapedVersion/sbom/$namespaceSuffix"
    creationInfo = @{
        created = $generatedAtIso
        creators = @("Tool: openclaw-zig-release-evidence/1.0.0")
    }
    packages = $spdxPackages
    relationships = $spdxRelationships
}

$builderId = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_SERVER_URL) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY) -and -not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKFLOW)) {
    "$($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/workflows/$($env:GITHUB_WORKFLOW)"
} else {
    "https://github.com/$Repository/.github/workflows/release-preview.yml"
}

$invocationId = if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_RUN_ID)) {
    $env:GITHUB_RUN_ID
} else {
    "local"
}

$provenance = @{
    _type = "https://in-toto.io/Statement/v1"
    subject = $subjects
    predicateType = "https://slsa.dev/provenance/v1"
    predicate = @{
        buildDefinition = @{
            buildType = "https://github.com/adybag14-cyber/openclaw-zig-port/.github/workflows/release-preview.yml@v1"
            externalParameters = @{
                version = $Version
                repository = $Repository
            }
            internalParameters = @{
                artifactCount = $artifactFiles.Count
            }
            resolvedDependencies = @(
                @{
                    uri = "git+https://github.com/$Repository.git"
                    digest = @{
                        sha1 = $Commit
                    }
                }
            )
        }
        runDetails = @{
            builder = @{
                id = $builderId
            }
            metadata = @{
                invocationId = $invocationId
                startedOn = $generatedAtIso
                finishedOn = $finishedAtIso
            }
            byproducts = $provenanceByproducts
        }
    }
}

$manifestPath = Join-Path $OutputDir "release-manifest.json"
$sbomPath = Join-Path $OutputDir "sbom.spdx.json"
$provenancePath = Join-Path $OutputDir "provenance.intoto.json"

$manifest | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$sbom | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $sbomPath -Encoding utf8
$provenance | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $provenancePath -Encoding utf8

Write-Output "Release evidence generated:"
Write-Output "- $manifestPath"
Write-Output "- $sbomPath"
Write-Output "- $provenancePath"
