<#
.SYNOPSIS
  Release management shared by Deploy-Release.ps1 and Rollback-Release.ps1.
.DESCRIPTION
  Owns the on-server layout and the state file:
    <DeployRoot>/<component>/releases/<version>/   one immutable folder per release
    <DeployRoot>/<component>/state.json            active / previous / knownGood / inProgress / history
    <DeployRoot>/<component>/logs/                 one transcript per run
  Talks to IIS only through IisAdapter, so the same logic runs in Mock and Iis mode.
  Scripts import this module only; it loads the adapter and exposes Initialize-ReleaseManager.
#>

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'IisAdapter.psm1') -Force

$script:Mode = $null

function Initialize-ReleaseManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Iis', 'Mock')] [string] $Mode,
        [string] $MockRoot
    )
    $script:Mode = $Mode
    Initialize-IisAdapter -Mode $Mode -MockRoot $MockRoot
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO'
    )
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Write-Host "$stamp [$Level] $Message"
}

# ---------- layout ----------
function Get-ComponentLayout {
    param([Parameter(Mandatory)] [string] $DeployRoot, [Parameter(Mandatory)] [string] $Component)
    $root = Join-Path $DeployRoot $Component
    $layout = @{
        Root      = $root
        Releases  = Join-Path $root 'releases'
        Logs      = Join-Path $root 'logs'
        StateFile = Join-Path $root 'state.json'
    }
    New-Item -ItemType Directory -Force -Path $layout.Releases, $layout.Logs | Out-Null
    return $layout
}

# ---------- state ----------
function Get-ReleaseState {
    param([Parameter(Mandatory)] [hashtable] $Layout, [Parameter(Mandatory)] [string] $Component)
    if (Test-Path -LiteralPath $Layout.StateFile) {
        return Get-Content -LiteralPath $Layout.StateFile -Raw | ConvertFrom-Json -AsHashtable
    }
    # First run on this server: nothing is active yet.
    return @{ component = $Component; active = $null; previous = $null; knownGood = $null; inProgress = $null; history = @() }
}

function Save-ReleaseState {
    param([Parameter(Mandatory)] [hashtable] $Layout, [Parameter(Mandatory)] [hashtable] $State)
    $State['updatedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    # Write to a temp file, then move: a crash mid-write can never leave a half-written state file.
    $tmp = "$($Layout.StateFile).tmp"
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp
    Move-Item -LiteralPath $tmp -Destination $Layout.StateFile -Force
}

function Add-StateHistory {
    param([hashtable] $State, [string] $Action, [string] $Version, [string] $Result, [string] $Detail = '')
    $entry = @{ at = (Get-Date).ToUniversalTime().ToString('o'); action = $Action; version = $Version; result = $Result; detail = $Detail }
    # Direct assignment keeps the array; assigning the output of an `if` would unroll a single element.
    $existing = @()
    if ($State['history']) { $existing = @($State['history']) }
    $State['history'] = @($existing + $entry)
}


# ---------- package ----------
function Test-PackageChecksum {
    param([Parameter(Mandatory)] [string] $PackagePath, [Parameter(Mandatory)] [string] $ChecksumPath)
    # sha256sum format is "<hash>  <filename>"; only the hash matters.
    $expected = ((Get-Content -LiteralPath $ChecksumPath -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $PackagePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($expected -ne $actual) { throw "Checksum mismatch for $PackagePath (expected $expected, got $actual)." }
    Write-Log "Checksum verified: $actual"
}

function Expand-ReleasePackage {
    param([Parameter(Mandatory)] [string] $PackagePath, [Parameter(Mandatory)] [hashtable] $Layout)
    # Extract into a staging folder; the real release folder appears only once extraction is complete.
    $staging = Join-Path $Layout.Releases ('staging-' + [guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $PackagePath -DestinationPath $staging -Force

    $manifestFile = Join-Path $staging 'manifest.json'
    if (-not (Test-Path -LiteralPath $manifestFile)) {
        Remove-Item -LiteralPath $staging -Recurse -Force
        throw 'Package has no manifest.json; refusing to deploy an untraceable build.'
    }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json -AsHashtable
    $version = $manifest['version']
    $target = Join-Path $Layout.Releases $version

    if (Test-Path -LiteralPath $target) {
        # Releases are immutable. The same version may be redeployed, but never with different content.
        $existing = Get-Content -LiteralPath (Join-Path $target 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
        Remove-Item -LiteralPath $staging -Recurse -Force
        if ($existing['commit'] -ne $manifest['commit']) {
            throw "Release $version already exists on the server with commit $($existing['commit']); refusing to overwrite it with commit $($manifest['commit'])."
        }
        Write-Log "Release $version already present with the same commit; reusing it." 'WARN'
    }
    else {
        Move-Item -LiteralPath $staging -Destination $target   # a rename on the same volume is atomic
        Write-Log "Extracted release $version (commit $($manifest['commit']))"
    }
    return @{ Path = $target; Manifest = $manifest }
}

# ---------- configuration ----------
function Write-FrontendRuntimeConfig {
    param([Parameter(Mandatory)] [string] $ReleasePath, [Parameter(Mandatory)] [string] $ApiBaseUrl)
    # Environment-specific but NON-secret: this file is downloaded by every browser.
    @{ apiBaseUrl = $ApiBaseUrl } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ReleasePath 'config.json')
    Write-Log "Wrote config.json (apiBaseUrl=$ApiBaseUrl)"
}

function Assert-AppPoolSecretsProvisioned {
    param([Parameter(Mandatory)] [string] $AppPoolName, [string[]] $RequiredNames)
    # Secrets are provisioned on the server by operations. The pipeline verifies presence by NAME only
    # and never reads a value, so a missing secret fails the deploy before anything is switched.
    if (-not $RequiredNames) { return }
    $present = Get-AppPoolEnvironmentVariableNames -AppPoolName $AppPoolName
    $missing = @($RequiredNames | Where-Object { $_ -notin $present })
    if ($missing.Count -gt 0) {
        throw "App pool '$AppPoolName' is missing required environment variables: $($missing -join ', '). Provision them on the server first."
    }
    Write-Log "Preflight: required app pool variables present ($($RequiredNames -join ', '))"
}

# ---------- switch + verify ----------
function Invoke-ReleaseActivation {
    param(
        [Parameter(Mandatory)] [string] $Component,
        [Parameter(Mandatory)] [hashtable] $Layout,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $SiteName,
        [Parameter(Mandatory)] [string] $AppPoolName,
        [string] $HealthUrl,
        [int] $HealthRetries = 5,
        [int] $HealthDelaySeconds = 2
    )
    $releasePath = Join-Path $Layout.Releases $Version
    if (-not (Test-Path -LiteralPath $releasePath)) { throw "Release folder not found: $releasePath" }

    # Stop -> repoint -> start. The previous folder is untouched, so switching back is the same three steps.
    Stop-SiteAppPool -AppPoolName $AppPoolName
    Set-SitePhysicalPath -SiteName $SiteName -Path $releasePath
    Start-SiteAppPool -AppPoolName $AppPoolName

    $healthScript = Join-Path $PSScriptRoot 'Test-Health.ps1'
    if ($script:Mode -eq 'Mock') {
        & $healthScript -Mode Mock -ReleasePath $releasePath -Component $Component -Retries $HealthRetries -DelaySeconds $HealthDelaySeconds
    }
    else {
        & $healthScript -Mode Iis -Url $HealthUrl -Retries $HealthRetries -DelaySeconds $HealthDelaySeconds
    }
    return ($LASTEXITCODE -eq 0)
}

# ---------- retention ----------
function Remove-OldReleases {
    param([Parameter(Mandatory)] [hashtable] $Layout, [Parameter(Mandatory)] [hashtable] $State, [int] $Keep = 5)
    # A leftover staging folder means an earlier run was interrupted before its rename; it is safe to remove.
    Get-ChildItem -LiteralPath $Layout.Releases -Directory -Filter 'staging-*' | ForEach-Object {
        Write-Log "Removing interrupted staging folder $($_.Name)" 'WARN'
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
    # Never delete a release we might still switch to.
    $protected = @($State['active'], $State['previous'], $State['knownGood']) | Where-Object { $_ }
    $candidates = Get-ChildItem -LiteralPath $Layout.Releases -Directory |
        Where-Object { $_.Name -notin $protected } |
        Sort-Object { [version] $_.Name } -Descending
    $toRemove = @($candidates | Select-Object -Skip ([Math]::Max($Keep - $protected.Count, 0)))
    foreach ($dir in $toRemove) {
        Write-Log "Pruning old release $($dir.Name)"
        Remove-Item -LiteralPath $dir.FullName -Recurse -Force
    }
}
function Set-AppPoolRuntimeEnvironment {
    param([Parameter(Mandatory)] [string] $AppPoolName, [Parameter(Mandatory)] [string] $EnvironmentName)
    # Non-secret. Selects appsettings.<Environment>.json inside the API and is reported by ASP.NET Core.
    Set-AppPoolEnvironmentVariable -AppPoolName $AppPoolName -Name 'ASPNETCORE_ENVIRONMENT' -Value $EnvironmentName
}


Export-ModuleMember -Function Initialize-ReleaseManager, Write-Log, Get-ComponentLayout,
    Get-ReleaseState, Save-ReleaseState, Add-StateHistory, Test-PackageChecksum, Expand-ReleasePackage,
    Write-FrontendRuntimeConfig, Assert-AppPoolSecretsProvisioned, Invoke-ReleaseActivation, Remove-OldReleases,
    Set-AppPoolRuntimeEnvironment

