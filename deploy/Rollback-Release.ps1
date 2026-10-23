<#
.SYNOPSIS
  Manually switches a component to a release that is already on the server, then verifies health.
.DESCRIPTION
  Target = -TargetVersion, or the recorded previous release when omitted.
  No download, no extraction: rollback only repoints IIS at an existing, immutable release folder.
  A release that is no longer on the server must be redeployed from its GitHub Release (cd-deploy).
  Exit codes: 0 switched and healthy, 1 switched but unhealthy, 2 aborted before switching.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('frontend', 'backend')] [string] $Component,
    [Parameter(Mandatory)] [string] $DeployRoot,
    [Parameter(Mandatory)] [string] $SiteName,
    [Parameter(Mandatory)] [string] $AppPoolName,
    [string] $TargetVersion,                   # default: state.previous
    [ValidateSet('Iis', 'Mock')] [string] $Mode = 'Mock',
    [string] $HealthUrl,                       # Iis mode
    [int] $HealthRetries = 5,
    [int] $HealthDelaySeconds = 2
)

$ErrorActionPreference = 'Stop'
if ($Mode -eq 'Iis' -and -not $HealthUrl) { throw 'Iis mode requires -HealthUrl.' }

Import-Module (Join-Path $PSScriptRoot 'ReleaseManager.psm1') -Force
Initialize-ReleaseManager -Mode $Mode -MockRoot (Join-Path $DeployRoot '_iis-mock')

$layout  = Get-ComponentLayout -DeployRoot $DeployRoot -Component $Component
$logFile = Join-Path $layout.Logs ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-rollback.log')
Start-Transcript -Path $logFile | Out-Null

$exitCode = 2
$result = @{ component = $Component; from = $null; to = $null; outcome = 'aborted'; logFile = $logFile }

try {
    $state   = Get-ReleaseState -Layout $layout -Component $Component
    $current = $state['active']
    $target  = if ($TargetVersion) { $TargetVersion } else { $state['previous'] }
    $result.from = $current
    $result.to   = $target

    # Validation happens before anything changes; each message tells the operator what to do instead.
    if (-not $target) { throw 'No -TargetVersion given and no previous release is recorded; nothing to roll back to.' }
    if ($target -eq $current) { throw "Version $target is already the active release." }
    if (-not (Test-Path -LiteralPath (Join-Path $layout.Releases $target))) {
        throw "Release $target is not on this server (pruned or never deployed here). Redeploy it from its GitHub Release instead."
    }

    Write-Log "Rollback start: component=$Component mode=$Mode from=$current to=$target"
    $state['inProgress'] = $target
    Save-ReleaseState -Layout $layout -State $state

    # Same switch-and-verify as a deploy and as the automatic rollback: one definition of "activate".
    $healthy = Invoke-ReleaseActivation -Component $Component -Layout $layout -Version $target `
        -SiteName $SiteName -AppPoolName $AppPoolName -HealthUrl $HealthUrl `
        -HealthRetries $HealthRetries -HealthDelaySeconds $HealthDelaySeconds

    if ($healthy) {
        $state['previous']  = $current          # so a roll-forward is one more rollback command
        $state['active']    = $target
        $state['knownGood'] = $target           # verified healthy just now
        Add-StateHistory -State $state -Action 'rollback' -Version $target -Result 'success' -Detail "from $current"
        Write-Log "Rollback succeeded: $target is active and healthy (previous: $current)"
        $result.outcome = 'success'
        $exitCode = 0
    }
    else {
        # The site does point at $target now; the state records the truth instead of pretending otherwise.
        $state['active'] = $target
        Add-StateHistory -State $state -Action 'rollback' -Version $target -Result 'failed' -Detail "from $current; health check failed"
        Write-Log "Rollback to $target activated but FAILED its health check; manual intervention required" 'ERROR'
        $result.outcome = 'unhealthy'
        $exitCode = 1
    }
    $state['inProgress'] = $null
    Save-ReleaseState -Layout $layout -State $state
}
catch {
    Write-Log "Rollback aborted: $($_.Exception.Message)" 'ERROR'
    $exitCode = 2
}
finally {
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $layout.Root 'last-rollback.json')
    Stop-Transcript | Out-Null
}

exit $exitCode
