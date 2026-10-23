<#
.SYNOPSIS
  Health check for a deployed component. Exit code 0 = healthy, 1 = unhealthy.
.DESCRIPTION
  Iis mode : polls an HTTP endpoint until it returns 200 or retries are exhausted.
  Mock mode: no server exists, so health = the release folder contains the component's
             entry file. MOCK_HEALTH=fail forces a failure to demonstrate automatic rollback.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Iis', 'Mock')] [string] $Mode,
    [string] $Url,                                            # Iis mode
    [string] $ReleasePath,                                    # Mock mode
    [ValidateSet('frontend', 'backend')] [string] $Component, # Mock mode
    [int] $Retries = 5,
    [int] $DelaySeconds = 2
)

$ErrorActionPreference = 'Stop'

if ($Mode -eq 'Iis' -and -not $Url) { throw 'Iis mode requires -Url.' }
if ($Mode -eq 'Mock' -and -not ($ReleasePath -and $Component)) { throw 'Mock mode requires -ReleasePath and -Component.' }

function Test-Once {
    if ($Mode -eq 'Mock') {
        # Failure injection for demos: only the named version is unhealthy, so a rollback to any other version passes.
        $version = Split-Path $ReleasePath -Leaf
        if ($env:MOCK_UNHEALTHY_VERSION -and $version -eq $env:MOCK_UNHEALTHY_VERSION) { return $false }
        $entryFile = if ($Component -eq 'backend') { 'Api.dll' } else { 'index.html' }
        return Test-Path -LiteralPath (Join-Path $ReleasePath $entryFile)
    }

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec 5
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    if (Test-Once) {
        Write-Host "Health check passed (attempt $attempt/$Retries)."
        exit 0
    }
    Write-Host "Health check attempt $attempt/$Retries failed."
    if ($attempt -lt $Retries) { Start-Sleep -Seconds $DelaySeconds }
}

Write-Host "Health check FAILED after $Retries attempts."
exit 1
