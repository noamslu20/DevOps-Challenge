<#
.SYNOPSIS
  Infrastructure adapter: the only code in the repo that talks to IIS.
.DESCRIPTION
  Each function has two implementations, selected once by Initialize-IisAdapter:
    Iis  - real WebAdministration cmdlets. Requires Windows + IIS + .NET Hosting Bundle.
           Written and reviewed for this assessment, not executable without a Windows host.
    Mock - a file-based simulation: <MockRoot>/sites/<site>.json and <MockRoot>/apppools/<pool>.json
           hold the same facts IIS would (physical path, pool state, env variable names).
  The orchestration layer (ReleaseManager) calls these functions and never knows which mode is active.
#>

$ErrorActionPreference = 'Stop'

# Module-level state, set by Initialize-IisAdapter.
$script:Mode = $null
$script:MockRoot = $null

function Initialize-IisAdapter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Iis', 'Mock')] [string] $Mode,
        [string] $MockRoot
    )
    $script:Mode = $Mode
    if ($Mode -eq 'Mock') {
        if (-not $MockRoot) { throw 'Mock mode requires -MockRoot.' }
        $script:MockRoot = $MockRoot
        New-Item -ItemType Directory -Force -Path (Join-Path $MockRoot 'sites'), (Join-Path $MockRoot 'apppools') | Out-Null
        Write-Host "[iis:mock] simulated IIS state under $MockRoot"
    }
    else {
        if (-not $IsWindows) { throw 'Iis mode requires Windows with IIS installed.' }
        Import-Module WebAdministration -ErrorAction Stop   # installed together with IIS
        Write-Host '[iis] WebAdministration module loaded'
    }
}

function Assert-Initialized {
    if (-not $script:Mode) { throw 'Call Initialize-IisAdapter before using the adapter.' }
}

# ---------- mock persistence helpers ----------
function Get-MockFile([string] $Kind, [string] $Name) {
    Join-Path $script:MockRoot $Kind "$Name.json"
}

function Read-MockObject([string] $Kind, [string] $Name) {
    $file = Get-MockFile $Kind $Name
    if (Test-Path -LiteralPath $file) {
        return Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
    }
    return $null
}

function Write-MockObject([string] $Kind, [string] $Name, [hashtable] $Object) {
    $Object | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Get-MockFile $Kind $Name)
}

# ---------- site physical path ----------
function Get-SitePhysicalPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SiteName)
    Assert-Initialized
    if ($script:Mode -eq 'Mock') {
        $site = Read-MockObject 'sites' $SiteName
        if ($site) { return $site['physicalPath'] }
        return $null                                        # site not created yet: first deploy
    }
    $site = Get-Website -Name $SiteName
    if (-not $site) { throw "IIS site '$SiteName' not found." }
    return $site.physicalPath
}

function Set-SitePhysicalPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SiteName,
        [Parameter(Mandatory)] [string] $Path
    )
    Assert-Initialized
    if ($script:Mode -eq 'Mock') {
        $site = Read-MockObject 'sites' $SiteName
        if (-not $site) { $site = @{ name = $SiteName } }
        $site['physicalPath'] = $Path
        Write-MockObject 'sites' $SiteName $site
        Write-Host "[iis:mock] site '$SiteName' physicalPath -> $Path"
        return
    }
    # Repointing the site IS the release switch: the previous release folder is left untouched.
    Set-ItemProperty -Path "IIS:\Sites\$SiteName" -Name physicalPath -Value $Path
    Write-Host "[iis] site '$SiteName' physicalPath -> $Path"
}

# ---------- app pool start / stop ----------
function Wait-AppPoolState {
    param([string] $AppPoolName, [string] $State, [int] $TimeoutSeconds = 30)
    # IIS passes through Stopping/Starting; switching while a worker process still runs would race it.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-WebAppPoolState -Name $AppPoolName).Value -ne $State) {
        if ((Get-Date) -gt $deadline) { throw "App pool '$AppPoolName' did not reach '$State' within $TimeoutSeconds s." }
        Start-Sleep -Milliseconds 500
    }
}

function Set-MockAppPoolState([string] $AppPoolName, [string] $State) {
    $pool = Read-MockObject 'apppools' $AppPoolName
    if (-not $pool) { $pool = @{ name = $AppPoolName; environmentVariables = @{} } }
    $pool['state'] = $State
    Write-MockObject 'apppools' $AppPoolName $pool
    Write-Host "[iis:mock] app pool '$AppPoolName' -> $State"
}

function Stop-SiteAppPool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $AppPoolName)
    Assert-Initialized
    if ($script:Mode -eq 'Mock') { Set-MockAppPoolState $AppPoolName 'Stopped'; return }
    if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $AppPoolName
        Wait-AppPoolState -AppPoolName $AppPoolName -State 'Stopped'
    }
    Write-Host "[iis] app pool '$AppPoolName' -> Stopped"
}

function Start-SiteAppPool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $AppPoolName)
    Assert-Initialized
    if ($script:Mode -eq 'Mock') { Set-MockAppPoolState $AppPoolName 'Started'; return }
    if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Started') {
        Start-WebAppPool -Name $AppPoolName
        Wait-AppPoolState -AppPoolName $AppPoolName -State 'Started'
    }
    Write-Host "[iis] app pool '$AppPoolName' -> Started"
}

# ---------- app pool environment variables ----------
# The API receives runtime configuration as per-app-pool environment variables (applicationHost.config).
# Operations provision the secret ones on the server; the pipeline only verifies that the NAMES exist.
# These functions log names, never values.
$script:EnvFilterTemplate = "system.applicationHost/applicationPools/add[@name='{0}']/environmentVariables"

function Get-AppPoolEnvironmentVariableNames {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $AppPoolName)
    Assert-Initialized
    if ($script:Mode -eq 'Mock') {
        $pool = Read-MockObject 'apppools' $AppPoolName
        if ($pool -and $pool['environmentVariables']) { return @($pool['environmentVariables'].Keys) }
        return @()
    }
    $filter = $script:EnvFilterTemplate -f $AppPoolName
    $items = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter -Name Collection
    return @($items | ForEach-Object { $_.name })
}

function Set-AppPoolEnvironmentVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $AppPoolName,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Value
    )
    Assert-Initialized
    if ($script:Mode -eq 'Mock') {
        $pool = Read-MockObject 'apppools' $AppPoolName
        if (-not $pool) { $pool = @{ name = $AppPoolName; state = 'Stopped'; environmentVariables = @{} } }
        $pool['environmentVariables'][$Name] = $Value
        Write-MockObject 'apppools' $AppPoolName $pool
        Write-Host "[iis:mock] app pool '$AppPoolName' env '$Name' set"
        return
    }
    $filter = $script:EnvFilterTemplate -f $AppPoolName
    $existing = Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter -Name Collection |
        Where-Object { $_.name -eq $Name }
    if ($existing) {
        Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter "$filter/add[@name='$Name']" -Name value -Value $Value
    }
    else {
        Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter $filter -Name '.' -Value @{ name = $Name; value = $Value }
    }
    Write-Host "[iis] app pool '$AppPoolName' env '$Name' set"
}

Export-ModuleMember -Function Initialize-IisAdapter, Get-SitePhysicalPath, Set-SitePhysicalPath,
    Stop-SiteAppPool, Start-SiteAppPool, Get-AppPoolEnvironmentVariableNames, Set-AppPoolEnvironmentVariable
