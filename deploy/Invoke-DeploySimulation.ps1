<#
.SYNOPSIS
  Demonstrates and verifies the full release lifecycle in mock mode.
.DESCRIPTION
  Scenario: deploy 1.0.1 -> deploy 1.0.2 -> deploy unhealthy 1.0.3 (automatic rollback to 1.0.2)
            -> manual rollback to 1.0.1 -> roll forward to 1.0.2 -> deploy with a missing secret (preflight abort).
  Plays two roles: operations (provisions the required app-pool variable NAMES through the adapter)
  and the pipeline (runs Deploy-Release.ps1 / Rollback-Release.ps1 as the CD workflow would).
  Runs locally and in ci-deploy-scripts.yml. Exit code 0 only if every expectation holds.
#>
[CmdletBinding()]
param(
    [string] $WorkRoot = (Join-Path ([IO.Path]::GetTempPath()) 'deploy-simulation'),
    [switch] $KeepWorkRoot   # CI keeps it to upload state.json and logs as evidence
)

$ErrorActionPreference = 'Stop'
$deploy   = Join-Path $PSScriptRoot 'Deploy-Release.ps1'
$rollback = Join-Path $PSScriptRoot 'Rollback-Release.ps1'

if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
$packages   = (New-Item -ItemType Directory -Force -Path (Join-Path $WorkRoot 'packages')).FullName
$deployRoot = Join-Path $WorkRoot 'apps'
$component  = 'backend'
$site       = 'api'
$pool       = 'api-pool'
$required   = @('ConnectionStrings__Default')

# ---------- helpers ----------
$script:failures = 0

function Assert-Equal($Expected, $Actual, [string] $What) {
    if ("$Expected" -eq "$Actual") { Write-Host "  PASS  $What = $Actual" -ForegroundColor Green }
    else { Write-Host "  FAIL  $What expected '$Expected' got '$Actual'" -ForegroundColor Red; $script:failures++ }
}

function Get-State      { Get-Content -Raw (Join-Path $deployRoot $component 'state.json')       | ConvertFrom-Json }
function Get-LastDeploy { Get-Content -Raw (Join-Path $deployRoot $component 'last-deploy.json') | ConvertFrom-Json }
function Step([string] $Title) { Write-Host "`n=== $Title ===" -ForegroundColor Cyan }

function New-FakePackage([string] $Version) {
    # Same shape as a CI artifact: entry file + manifest.json inside the zip, sha256 file next to it.
    $src = New-Item -ItemType Directory -Force -Path (Join-Path $packages "src-$Version")
    Set-Content -Path (Join-Path $src 'Api.dll') -Value "fake build $Version"
    @{ component = $component; version = $Version; commit = "commit-$Version" } | ConvertTo-Json |
        Set-Content -Path (Join-Path $src 'manifest.json')
    $zip = Join-Path $packages "$component-$Version.zip"
    Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -Force
    "$((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower())  $(Split-Path $zip -Leaf)" | Set-Content -Path "$zip.sha256"
}

function Invoke-Deploy([string] $Version, [string[]] $Required = $required) {
    & $deploy -Component $component `
        -PackagePath  (Join-Path $packages "$component-$Version.zip") `
        -ChecksumPath (Join-Path $packages "$component-$Version.zip.sha256") `
        -DeployRoot $deployRoot -SiteName $site -AppPoolName $pool `
        -AspNetCoreEnvironment Production -RequiredAppPoolVariables $Required `
        -HealthRetries 2 -HealthDelaySeconds 1
    return $LASTEXITCODE
}

function Invoke-Rollback([string] $TargetVersion) {
    $extra = @{}
    if ($TargetVersion) { $extra['TargetVersion'] = $TargetVersion }
    & $rollback -Component $component -DeployRoot $deployRoot -SiteName $site -AppPoolName $pool `
        -HealthRetries 2 -HealthDelaySeconds 1 @extra
    return $LASTEXITCODE
}

# ---------- scenario ----------
Step 'Setup: build three fake release packages'
foreach ($v in '1.0.1', '1.0.2', '1.0.3') { New-FakePackage $v }

Step 'Setup: operations provisions the runtime secret NAME on the server (value is fake)'
Import-Module (Join-Path $PSScriptRoot 'IisAdapter.psm1') -Force
Initialize-IisAdapter -Mode Mock -MockRoot (Join-Path $deployRoot '_iis-mock')
Set-AppPoolEnvironmentVariable -AppPoolName $pool -Name 'ConnectionStrings__Default' -Value 'provisioned-by-operations'

Step '1. First deploy: 1.0.1 (nothing to roll back to yet)'
$code = Invoke-Deploy '1.0.1'
Assert-Equal 0 $code 'exit code'
Assert-Equal '1.0.1' (Get-State).active 'active'

Step '2. Second deploy: 1.0.2'
$code = Invoke-Deploy '1.0.2'
Assert-Equal 0 $code 'exit code'
Assert-Equal '1.0.2' (Get-State).active 'active'
Assert-Equal '1.0.1' (Get-State).previous 'previous'

Step '3. Failed deploy: 1.0.3 is unhealthy -> automatic rollback to 1.0.2'
$env:MOCK_UNHEALTHY_VERSION = '1.0.3'
try { $code = Invoke-Deploy '1.0.3' } finally { Remove-Item Env:MOCK_UNHEALTHY_VERSION }
Assert-Equal 1 $code 'exit code'
Assert-Equal 'rolled-back' (Get-LastDeploy).outcome 'outcome'
Assert-Equal '1.0.2' (Get-State).active 'active'
Assert-Equal '1.0.2' (Get-State).knownGood 'knownGood'

Step '4. Manual rollback to the previous release (1.0.1)'
$code = Invoke-Rollback
Assert-Equal 0 $code 'exit code'
Assert-Equal '1.0.1' (Get-State).active 'active'

Step '5. Roll forward again to 1.0.2'
$code = Invoke-Rollback -TargetVersion '1.0.2'
Assert-Equal 0 $code 'exit code'
Assert-Equal '1.0.2' (Get-State).active 'active'

Step '6. Preflight: a required secret is missing -> aborted before any switch'
$code = Invoke-Deploy -Version '1.0.3' -Required @('ConnectionStrings__Default', 'Jwt__SigningKey')
Assert-Equal 2 $code 'exit code'
Assert-Equal '1.0.2' (Get-State).active 'active (unchanged)'

Step 'Final state'
Get-Content -Raw (Join-Path $deployRoot $component 'state.json')

if (-not $KeepWorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }

Write-Host "`nSimulation finished with $script:failures failed expectation(s)."
if ($script:failures -eq 0) { exit 0 } else { exit 1 }
