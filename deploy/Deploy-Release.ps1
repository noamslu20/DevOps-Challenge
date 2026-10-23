<#
.SYNOPSIS
  Deploys one component release to IIS (or to the mock) with verification and automatic rollback.
.DESCRIPTION
  Stages: verify checksum -> extract into releases/<version> -> apply environment config ->
          preflight (required app-pool variables present) -> mark inProgress -> switch site ->
          health check -> success: record state, prune | failure: switch back to previous, verify, report.
  Exit codes: 0 deployed and healthy, 1 health failed (rolled back if a previous release existed), 2 aborted before switching.
  -Mode defaults to Mock: touching real IIS is opt-in, never accidental.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('frontend', 'backend')] [string] $Component,
    [Parameter(Mandatory)] [string] $PackagePath,
    [Parameter(Mandatory)] [string] $ChecksumPath,
    [Parameter(Mandatory)] [string] $DeployRoot,
    [Parameter(Mandatory)] [string] $SiteName,
    [Parameter(Mandatory)] [string] $AppPoolName,
    [ValidateSet('Iis', 'Mock')] [string] $Mode = 'Mock',
    [string] $HealthUrl,                       # Iis mode
    [int] $HealthRetries = 5,
    [int] $HealthDelaySeconds = 2,
    [string] $AspNetCoreEnvironment,           # backend: e.g. Production / Staging
    [string[]] $RequiredAppPoolVariables = @(),# backend: names that operations must have provisioned
    [string] $FrontendApiBaseUrl,              # frontend: written to config.json
    [int] $ReleasesToKeep = 5
)

$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Iis' -and -not $HealthUrl) { throw 'Iis mode requires -HealthUrl.' }

Import-Module (Join-Path $PSScriptRoot 'ReleaseManager.psm1') -Force
Initialize-ReleaseManager -Mode $Mode -MockRoot (Join-Path $DeployRoot '_iis-mock')

$layout  = Get-ComponentLayout -DeployRoot $DeployRoot -Component $Component
$logFile = Join-Path $layout.Logs ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-deploy.log')
Start-Transcript -Path $logFile | Out-Null   # every line below is also kept on the server

$exitCode = 2
$result = @{ component = $Component; version = $null; previousActive = $null; outcome = 'aborted'; rolledBack = $false; logFile = $logFile }

try {
    Write-Log "Deploy start: component=$Component mode=$Mode package=$(Split-Path $PackagePath -Leaf)"

    # 1. Integrity: the bytes we received are the bytes CI produced.
    Test-PackageChecksum -PackagePath $PackagePath -ChecksumPath $ChecksumPath

    # 2. Extract next to the current release, never over it.
    $release = Expand-ReleasePackage -PackagePath $PackagePath -Layout $layout
    $version = $release.Manifest['version']
    $result.version = $version

    # 3. Environment-specific configuration, outside source and artifact.
    if ($Component -eq 'frontend') {
        if ($FrontendApiBaseUrl) { Write-FrontendRuntimeConfig -ReleasePath $release.Path -ApiBaseUrl $FrontendApiBaseUrl }
    }
    else {
        if ($AspNetCoreEnvironment) { Set-AppPoolRuntimeEnvironment -AppPoolName $AppPoolName -EnvironmentName $AspNetCoreEnvironment }
        # 4. Preflight: fail here, while the old release is still serving, rather than after the switch.
        Assert-AppPoolSecretsProvisioned -AppPoolName $AppPoolName -RequiredNames $RequiredAppPoolVariables
    }

    # 5. Record intent. If the process dies after this line, inProgress tells the next operator what happened.
    $state = Get-ReleaseState -Layout $layout -Component $Component
    $previousActive = $state['active']
    $result.previousActive = $previousActive
    $state['inProgress'] = $version
    Save-ReleaseState -Layout $layout -State $state

    # 6 + 7. Switch and verify.
    $healthy = Invoke-ReleaseActivation -Component $Component -Layout $layout -Version $version `
        -SiteName $SiteName -AppPoolName $AppPoolName -HealthUrl $HealthUrl `
        -HealthRetries $HealthRetries -HealthDelaySeconds $HealthDelaySeconds

    if ($healthy) {
        if ($previousActive -and $previousActive -ne $version) { $state['previous'] = $previousActive }
        $state['active']    = $version
        $state['knownGood'] = $version
        Add-StateHistory -State $state -Action 'deploy' -Version $version -Result 'success' -Detail "commit $($release.Manifest['commit'])"
        $result.outcome = 'success'
        $exitCode = 0
    }
    else {
        Add-StateHistory -State $state -Action 'deploy' -Version $version -Result 'failed' -Detail 'health check failed'
        if ($previousActive -and $previousActive -ne $version) {
            # Automatic rollback: the previous folder is intact, so activation is the same operation in reverse.
            Write-Log "Health check failed for $version; rolling back to $previousActive" 'ERROR'
            $restored = Invoke-ReleaseActivation -Component $Component -Layout $layout -Version $previousActive `
                -SiteName $SiteName -AppPoolName $AppPoolName -HealthUrl $HealthUrl `
                -HealthRetries $HealthRetries -HealthDelaySeconds $HealthDelaySeconds
            $result.rolledBack = $true
            if ($restored) {
                Add-StateHistory -State $state -Action 'auto-rollback' -Version $previousActive -Result 'success'
                Write-Log "Rolled back: $previousActive is active and healthy" 'WARN'
                $result.outcome = 'rolled-back'
            }
            else {
                Add-StateHistory -State $state -Action 'auto-rollback' -Version $previousActive -Result 'failed'
                Write-Log "Rollback to $previousActive also failed its health check; manual intervention required" 'ERROR'
                $result.outcome = 'rollback-failed'
            }
        }
        else {
            Write-Log "Health check failed and no previous release exists (first deploy); site left on $version, manual intervention required" 'ERROR'
            $result.outcome = 'failed-no-previous'
        }
        $exitCode = 1
    }

    # 8. Persist the outcome; the switch is over either way.
    $state['inProgress'] = $null
    Save-ReleaseState -Layout $layout -State $state
    if ($exitCode -eq 0) { Remove-OldReleases -Layout $layout -State $state -Keep $ReleasesToKeep }
    Write-Log "Deploy finished: outcome=$($result.outcome) active=$($state['active']) previous=$($state['previous']) knownGood=$($state['knownGood'])"
}
catch {
    # Reached only before or during the switch. inProgress is deliberately left as-is: it is the evidence.
    Write-Log "Deploy aborted: $($_.Exception.Message)" 'ERROR'
    $result.outcome = 'aborted'
    $exitCode = 2
}
finally {
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $layout.Root 'last-deploy.json')
    Stop-Transcript | Out-Null
}

exit $exitCode
