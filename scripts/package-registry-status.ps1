[CmdletBinding()]
param(
    [string]$Repository = "adybag14-cyber/openclaw-zig-port",
    [string]$ReleaseTag,
    [string]$NpmPackageName,
    [string]$NpmVersion,
    [string]$PythonPackageName,
    [string]$PythonVersion,
    [string]$OutputJsonPath = ".\release\package-registry-status.json",
    [string]$GitHubToken = $env:GITHUB_TOKEN
)

$ErrorActionPreference = "Stop"

function Get-StatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    if ($null -ne $ErrorRecord.Exception.Response) {
        try {
            if ($null -ne $ErrorRecord.Exception.Response.StatusCode) {
                return [int]$ErrorRecord.Exception.Response.StatusCode
            }
        } catch {
        }

        try {
            return [int]$ErrorRecord.Exception.Response.StatusCode.value__
        } catch {
        }
    }

    return $null
}

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$Headers = @{}
    )

    try {
        $response = Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
        return [pscustomobject]@{
            ok         = $true
            statusCode = 200
            body       = $response
            error      = $null
        }
    } catch {
        return [pscustomobject]@{
            ok         = $false
            statusCode = Get-StatusCode -ErrorRecord $_
            body       = $null
            error      = $_.Exception.Message
        }
    }
}

function New-RegistryState {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    return [ordered]@{
        name             = $Name
        checked          = $false
        packageExists    = $null
        versionRequested = $null
        versionExists    = $null
        statusCode       = $null
        error            = $null
        details          = [ordered]@{}
    }
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
try {
    $headers = @{
        "User-Agent" = "openclaw-zig-package-registry-status"
        "Accept"     = "application/vnd.github+json"
    }
    if ($GitHubToken) {
        $headers["Authorization"] = "Bearer $GitHubToken"
    }

    $resolvedNpmName = $NpmPackageName
    if ([string]::IsNullOrWhiteSpace($resolvedNpmName)) {
        $resolvedNpmName = "@adybag14-cyber/openclaw-zig-rpc-client"
    }

    $resolvedPythonName = $PythonPackageName
    if ([string]::IsNullOrWhiteSpace($resolvedPythonName)) {
        $resolvedPythonName = "openclaw-zig-rpc-client"
    }

    $report = [ordered]@{
        repository  = $Repository
        generatedAt = (Get-Date).ToUniversalTime().ToString("o")
        release     = [ordered]@{
            tag         = $ReleaseTag
            exists      = $null
            statusCode  = $null
            assetNames  = @()
            assetCount  = 0
            error       = $null
        }
        npm         = New-RegistryState -Name $resolvedNpmName
        pypi        = New-RegistryState -Name $resolvedPythonName
        summary     = [ordered]@{
            publicNpmVersionLive  = $null
            publicPypiVersionLive = $null
            releaseAssetsReady    = $null
            uvxFallbackReady      = $null
        }
    }

    if ($ReleaseTag) {
        $releaseUri = "https://api.github.com/repos/$Repository/releases/tags/$ReleaseTag"
        $releaseResponse = Invoke-JsonRequest -Uri $releaseUri -Headers $headers
        $report.release.statusCode = $releaseResponse.statusCode
        $report.release.error = $releaseResponse.error
        if ($releaseResponse.ok) {
            $report.release.exists = $true
            $assets = @($releaseResponse.body.assets)
            $report.release.assetNames = @($assets | ForEach-Object { [string]$_.name })
            $report.release.assetCount = $report.release.assetNames.Count
        } elseif ($releaseResponse.statusCode -eq 404) {
            $report.release.exists = $false
        }
    }

    if ($NpmPackageName) {
        $report.npm.checked = $true
        $report.npm.versionRequested = $NpmVersion
        $npmUri = "https://registry.npmjs.org/$([Uri]::EscapeDataString($NpmPackageName))"
        $npmResponse = Invoke-JsonRequest -Uri $npmUri
        $report.npm.statusCode = $npmResponse.statusCode
        $report.npm.error = $npmResponse.error
        if ($npmResponse.ok) {
            $report.npm.packageExists = $true
            $versions = @{}
            if ($null -ne $npmResponse.body.versions) {
                $versions = @($npmResponse.body.versions.PSObject.Properties.Name)
            }
            if ($NpmVersion) {
                $report.npm.versionExists = $versions -contains $NpmVersion
            }
            $distTags = [ordered]@{}
            if ($null -ne $npmResponse.body.'dist-tags') {
                foreach ($property in $npmResponse.body.'dist-tags'.PSObject.Properties) {
                    $distTags[$property.Name] = [string]$property.Value
                }
            }
            $report.npm.details = [ordered]@{
                distTags     = $distTags
                versionCount = $versions.Count
            }
        } elseif ($npmResponse.statusCode -eq 404) {
            $report.npm.packageExists = $false
            $report.npm.versionExists = $false
        }
    }

    if ($PythonPackageName) {
        $report.pypi.checked = $true
        $report.pypi.versionRequested = $PythonVersion
        $pypiUri = "https://pypi.org/pypi/$PythonPackageName/json"
        $pypiResponse = Invoke-JsonRequest -Uri $pypiUri
        $report.pypi.statusCode = $pypiResponse.statusCode
        $report.pypi.error = $pypiResponse.error
        if ($pypiResponse.ok) {
            $report.pypi.packageExists = $true
            $releases = @{}
            if ($null -ne $pypiResponse.body.releases) {
                $releases = @($pypiResponse.body.releases.PSObject.Properties.Name)
            }
            if ($PythonVersion) {
                $report.pypi.versionExists = $releases -contains $PythonVersion
            }
            $report.pypi.details = [ordered]@{
                latestVersion = [string]$pypiResponse.body.info.version
                versionCount  = $releases.Count
            }
        } elseif ($pypiResponse.statusCode -eq 404) {
            $report.pypi.packageExists = $false
            $report.pypi.versionExists = $false
        }
    }

    if ($ReleaseTag) {
        $assetNames = @($report.release.assetNames)
        $report.summary.releaseAssetsReady = $report.release.exists -and ($assetNames.Count -gt 0)
        $report.summary.uvxFallbackReady = $report.release.exists -and ($assetNames -contains "openclaw_zig_rpc_client-$PythonVersion-py3-none-any.whl" -or $assetNames -contains "openclaw_zig_rpc_client-$PythonVersion.tar.gz")
    }
    if ($NpmVersion) {
        $report.summary.publicNpmVersionLive = $report.npm.versionExists
    }
    if ($PythonVersion) {
        $report.summary.publicPypiVersionLive = $report.pypi.versionExists
    }

    $outputDirectory = Split-Path -Parent $OutputJsonPath
    if ($outputDirectory) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputJsonPath -Encoding utf8

    Write-Host ("Package registry status generated: {0}" -f (Resolve-Path $OutputJsonPath))
    if ($NpmPackageName) {
        Write-Host ("npmjs {0}: packageExists={1} versionRequested={2} versionExists={3}" -f $NpmPackageName, $report.npm.packageExists, $report.npm.versionRequested, $report.npm.versionExists)
    }
    if ($PythonPackageName) {
        Write-Host ("PyPI {0}: packageExists={1} versionRequested={2} versionExists={3}" -f $PythonPackageName, $report.pypi.packageExists, $report.pypi.versionRequested, $report.pypi.versionExists)
    }
    if ($ReleaseTag) {
        Write-Host ("Release {0}: exists={1} assets={2}" -f $ReleaseTag, $report.release.exists, $report.release.assetCount)
    }
    $global:LASTEXITCODE = 0
} finally {
    Pop-Location
}
