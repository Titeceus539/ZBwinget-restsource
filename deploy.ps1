#Requires -Version 7.4

<#
deploy.ps1 - FULL REBUILD LOOP for a winget REST source ("the winget repo").
One settings file: deploy-settings.psd1 (gitignored - holds real IDs).

  The loop:   -Destroy -> -Deploy -> -GetManifest -> -Ingest -> -ClientTest
  Every switch drives separately. Nothing auto-installs software on this PC
  (the install command is printed - installing stays a manual, approved step).

SWITCHES
  -Destroy                              delete the RG in deploy-settings.psd1
                                        (refuses protected groups; must type the name)
  -Deploy                               create everything via Microsoft.WinGet.RestSource,
                                        then repair identity/RBAC where the module leaves
                                        gaps, then wait until the endpoint answers
  -Verify                               read-only: discover + probe the endpoint
  -GetManifest -PackageId <id> [-Version <v>]
                                        pull one manifest version from microsoft/winget-pkgs
                                        into .\manifests\<id>\<v>\; use -Version list to list
  -Ingest -ManifestDir <dir>            push that folder into the repo (Add-WinGetManifest)
  -ClientTest [-SearchTerm <term>]      add winget source 'internal' (auto-elevates via
                                        UAC if needed) + winget search receipt

PREREQS  PowerShell 7.4+, az CLI (logged in), Az PowerShell module,
         Microsoft.WinGet.RestSource module (auto-installed if missing), Owner on the sub.
SECRETS  none stored. Host key fetched at run time; lives only in the winget source
         definition (+ a TEMP file during an elevated add, deleted right after).

KNOWN LIMITS (documented, not hidden)
  - Manifests pointing their InstallerUrl at a vendor CDN install fine on a normal PC
    but will fail on the internet-locked PAW. PAW phase = rewrite InstallerUrl to your
    own storage blob (hash still verified against the manifest). Not in scope here.
  - winget source add with --type Microsoft.Rest + ?code= key URL is the proven posture;
    the private-endpoint phase later drops ?code= entirely.
#>

param(
  [switch]$Destroy,
  [switch]$Deploy,
  [switch]$Verify,
  [switch]$GetManifest,
  [switch]$Ingest,
  [switch]$ClientTest,
  [string]$PackageId,
  [string]$Version,
  [string]$ManifestDir,
  [string]$SearchTerm   = '7zip',
  [string]$SourceAlias  = 'internal',
  [string]$SettingsFile = (Join-Path $PSScriptRoot 'deploy-settings.psd1'),
  [int]$ProbeTimeoutMin = 25
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------ settings
$settings = Import-PowerShellDataFile $SettingsFile
$TenantId       = [string]$settings.TenantId
$SubscriptionId = [string]$settings.SubscriptionId
$RG             = [string]$settings.ResourceGroup
$SourceName     = [string]$settings.Name
if (-not $RG -or -not $SourceName -or -not $TenantId -or -not $SubscriptionId) {
  throw 'deploy-settings.psd1 must define TenantId, SubscriptionId, Name, ResourceGroup.'
}

# -------------------------------------------------------------- guard rails
# Groups this script must NEVER touch, even if the settings file drifts.
$ProtectedExact = @('rg-winget-manual','rg-wingettest','rg-pawtest','tim_paw_gallery_rg','paw2-hp-rg')
foreach ($p in $ProtectedExact) { if ($RG -ieq $p) { throw "REFUSING: '$RG' is a protected resource group." } }
if ($RG -imatch '^(paw2|pawtest)') { throw "REFUSING: '$RG' matches a protected prefix (paw2*/pawtest*)." }

function Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Info { param($m) Write-Host "    $m" }

# ------------------------------------------------------------------ az login
function Ensure-Az {
  Step "Azure context (tenant $TenantId / sub $SubscriptionId)"
  Import-Module Az.Accounts -ErrorAction Stop
  $ctx = Get-AzContext
  if (-not $ctx -or $ctx.Subscription.Id -ne $SubscriptionId -or $ctx.Tenant.Id -ne $TenantId) {
    Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId | Out-Null
    Set-AzContext -Tenant $TenantId -SubscriptionId $SubscriptionId | Out-Null
  }
  $ctx = Get-AzContext
  if ($ctx.Tenant.Id -ne $TenantId -or $ctx.Subscription.Id -ne $SubscriptionId) {
    throw 'Azure context does not match deploy-settings.psd1.'
  }
  Info "connected as $($ctx.Account.Id)"
}

# ------------------------------------------------------- resource discovery
# Discover, never assume: the module names resources itself, so we read them back.
function Get-RepoResources {
  $app    = az functionapp list -g $RG --query '[0].{name:name, host:defaultHostName}' -o json 2>$null | ConvertFrom-Json
  $cosmos = az cosmosdb list -g $RG --query '[0].name' -o tsv 2>$null
  if (-not $app -or -not $cosmos) {
    throw "RG '$RG' has no function app and/or Cosmos account yet - run -Deploy first."
  }
  [pscustomobject]@{ App = $app; Cosmos = $cosmos; Url = "https://$($app.host)/api" }
}

# ----------------------------------------------------------- health probing
# Any completed HTTP exchange = host is up. Only >=500 means "keep waiting"
# (lesson from the 2026-10-20/21 503 storms - a 503 is NOT a live host).
function Test-RepoHealth {
  param([int]$TimeoutMin = $ProbeTimeoutMin)
  $r = Get-RepoResources
  $url = "$($r.Url)/information"
  Step "waiting for $url (max ${TimeoutMin} min)"
  $deadline = (Get-Date).AddMinutes($TimeoutMin)
  while ($true) {
    $resp = $null
    try { $resp = Invoke-WebRequest -Uri $url -TimeoutSec 30 -SkipHttpErrorCheck } catch { }
    if ($resp -and $resp.StatusCode) {
      $code = [int]$resp.StatusCode
      if ($code -eq 200) {
        Write-Host "[HOST_UP] $url -> 200" -ForegroundColor Green; return $true
      }
      if ($code -eq 401) {
        Write-Host '[HOST_UP] 401 = read endpoints are function-keyed (module stock posture; the source URL carries the key)' -ForegroundColor Green; return $true
      }
      if ($code -lt 500) {
        Write-Host "[HOST_UP] HTTP $code - host is serving; unexpected status, note it" -ForegroundColor Yellow; return $true
      }
      Write-Host "    $(Get-Date -Format HH:mm:ss) HTTP $code - function erroring, still waiting"
    } else {
      Write-Host "    $(Get-Date -Format HH:mm:ss) no HTTP answer yet (startup / RBAC propagation)"
    }
    if ((Get-Date) -gt $deadline) {
      Write-Host '[HOST_DOWN] no usable answer in time.' -ForegroundColor Red
      Info "diagnose: az functionapp log tailing -g $RG -n $($r.App.name)  (or portal: Log stream)"
      return $false
    }
    Start-Sleep -Seconds 20
  }
}

# ------------------------------------------- post-deploy identity/RBAC repair
# The module deploys Cosmos with disableLocalAuth=true but no identity wiring ->
# function has neither key nor identity -> 500s (cost a full session 2026-10-19).
# Fix, idempotent; skipped when the module already wired key auth.
function Set-RepoRepair {
  $r = Get-RepoResources
  Step "post-deploy checks (function '$($r.App.name)', cosmos '$($r.Cosmos)')"
  $dis = (az cosmosdb show -g $RG -n $r.Cosmos --query disableLocalAuth -o tsv) -eq 'true'
  if (-not $dis) { Info 'cosmos accepts key auth - module wiring intact, no repair needed'; return $r }
  Info 'cosmos has disableLocalAuth=true - applying managed-identity repair (proven 2026-10-19)'
  $principal = az functionapp identity assign -g $RG -n $r.App.name --query principalId -o tsv
  if (-not $principal) { throw 'identity assign returned no principalId' }
  $already = az cosmosdb sql role assignment list --account-name $r.Cosmos -g $RG --query "[?principalId=='$principal'].id" -o tsv 2>$null
  if (-not $already) {
    az cosmosdb sql role assignment create --account-name $r.Cosmos -g $RG --scope '/' `
      --role-definition-id '00000000-0000-0000-0000-000000000002' --principal-id $principal -o none
    Info 'granted Cosmos Built-in Data Contributor'
  } else { Info 'cosmos RBAC already in place' }
  az functionapp config appsettings set -g $RG -n $r.App.name --settings `
    "CosmosAccountEndpoint=https://$($r.Cosmos).documents.azure.com:443/" `
    CosmosDatabase=WinGet CosmosContainer=Manifests CosmosUseAadAuth=true -o none | Out-Null
  az functionapp restart -g $RG -n $r.App.name -o none
  Info 'settings set + restarted (RBAC may take ~10 min to propagate - the probe waits for it)'
  return $r
}

# ============================================================= -Destroy
if ($Destroy) {
  Step "DESTROY resource group '$RG' (subscription $SubscriptionId)"
  Ensure-Az
  Write-Host "Permanently deletes EVERYTHING in '$RG': function app, cosmos db, storage, key vault, app insights."
  $typed = Read-Host 'Type the resource group name to confirm'
  if ($typed -cne $RG) { throw 'confirmation mismatch - nothing was deleted.' }
  az group delete -n $RG --yes
  if (az group show -n $RG 2>$null) { throw "group '$RG' still exists after delete - investigate." }
  Write-Host "[DESTROYED] '$RG' is gone." -ForegroundColor Green
}

# ============================================================= -Deploy
if ($Deploy) {
  Step "DEPLOY winget REST source '$SourceName' -> RG '$RG' ($($settings.Region))"
  Ensure-Az
  if (-not (Get-Module -ListAvailable -Name Microsoft.WinGet.RestSource)) {
    Info 'installing Microsoft.WinGet.RestSource module (one-time)'
    Install-Module Microsoft.WinGet.RestSource -Scope CurrentUser -AllowClobber -Force
  }
  Import-Module Microsoft.WinGet.RestSource -ErrorAction Stop

  $sourceSettings = $settings.Clone()
  $sourceSettings.Remove('TenantId'); $sourceSettings.Remove('SubscriptionId')
  foreach ($k in 'TemplateFolderPath','ParameterOutputPath','RestSourcePath') {
    if ([string]::IsNullOrWhiteSpace([string]$sourceSettings[$k])) { $sourceSettings.Remove($k) }
  }
  Info 'calling New-WinGetSource (ARM deploy - expect ~10-40 min)'
  $ok = New-WinGetSource @sourceSettings
  if (-not $ok) { throw 'New-WinGetSource reported failure.' }

  Set-RepoRepair | Out-Null
  if (-not (Test-RepoHealth)) { throw 'endpoint did not come healthy after deploy - see probe output.' }
  Write-Host "`n[DEPLOY_DONE] repo is live. Next: -GetManifest -> -Ingest -> -ClientTest" -ForegroundColor Green
}

# ============================================================= -Verify
if ($Verify) {
  Step 'VERIFY (read-only)'
  $r = Get-RepoResources
  Info "function app: $($r.App.name)"
  Info "cosmos:       $($r.Cosmos)"
  Test-RepoHealth | Out-Null
}

# ============================================================= -GetManifest
function Get-GhHeader { @{ 'User-Agent' = 'ZBwinget-restsource-deploy'; Accept = 'application/vnd.github.raw' } }

if ($GetManifest) {
  if (-not $PackageId) { throw 'need -PackageId (id format: Publisher.Product, exact case - e.g. 7zip.7zip)' }
  $pub, $prod = $PackageId -split '\.', 2
  if (-not $prod) { $prod = $pub }
  $ghFolder = "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/$($pub[0])/$pub/$prod"
  if (-not $Version -or $Version -eq 'list') {
    Step "listing versions of $PackageId"
    (Invoke-RestMethod -Uri $ghFolder -Headers (Get-GhHeader)).name | Sort-Object -Property {[version]$_} -Descending -ErrorAction SilentlyContinue | Select-Object -First 15
    return
  }
  $apiBase = "$ghFolder/$Version"
  $outDir = Join-Path $PSScriptRoot "manifests\$PackageId\$Version"
  Step "pulling $PackageId $Version -> $outDir"
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  foreach ($f in @("$PackageId.yaml", "$PackageId.installer.yaml", "$PackageId.locale.en-US.yaml")) {
    try {
      Invoke-WebRequest -Uri ($apiBase + '/' + $f) -Headers (Get-GhHeader) -OutFile (Join-Path $outDir $f) -ErrorAction Stop
      Info "downloaded $f"
    } catch {
      $sc = $_.Exception.Response.StatusCode.value__
      if ($sc -eq 404 -and $f -like '*.locale.*') { Info "locale file absent for this version - skipping ($f)" }
      elseif ($sc -eq 404) { throw "missing required manifest file $f - PackageId/Version wrong or case-mismatch?" }
      else { throw }
    }
  }
  Write-Host "[MANIFEST_OK] $outDir" -ForegroundColor Green
}

# ============================================================= -Ingest
if ($Ingest) {
  if (-not (Test-Path -LiteralPath $ManifestDir)) { throw "need -ManifestDir <folder with the version yaml files>; got '$ManifestDir'" }
  Ensure-Az
  Import-Module Microsoft.WinGet.RestSource -ErrorAction Stop
  $r = Get-RepoResources
  Step "ingesting $ManifestDir -> function '$($r.App.name)'"
  Add-WinGetManifest -FunctionName $r.App.name -Path $ManifestDir
  Write-Host "[INGEST_OK] receipt check comes with -ClientTest (winget search)" -ForegroundColor Green
}

# ============================================================= -ClientTest
if ($ClientTest) {
  Ensure-Az
  $r = Get-RepoResources
  $key = az functionapp keys list -g $RG -n $r.App.name --query 'functionKeys.default' -o tsv
  if (-not $key) { throw 'could not fetch the function host key - is the app fully deployed?' }
  $endpoint = "$($r.Url)?code=$key"
  Step "adding winget source '$SourceAlias' -> repo"
  $added = $false
  try {
    winget source remove $SourceAlias 2>$null | Out-Null
    winget source add --name $SourceAlias --arg $endpoint --type Microsoft.Rest | Out-Host
    $added = ($LASTEXITCODE -eq 0)
  } catch { $added = $false }
  if (-not $added) {
    Info 'non-elevated add failed (machine scope wins needs admin) - retrying via elevated window'
    Info '>>> approve the UAC prompt that pops up'
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $tmpIn  = Join-Path ([IO.Path]::GetTempPath()) "winget-add-$stamp.ps1"
    $tmpOut = Join-Path ([IO.Path]::GetTempPath()) "winget-add-$stamp.txt"
    Set-Content -Path $tmpIn -Value @"
`$ErrorActionPreference = 'Continue'
winget source remove $SourceAlias 2>`$null
winget source add --name $SourceAlias --arg '$endpoint' --type Microsoft.Rest *>&1 | Out-File -Path '$tmpOut' -Encoding utf8
exit `$LASTEXITCODE
"@
    Start-Process pwsh -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File', $tmpIn)
    if (Test-Path $tmpOut) { Get-Content $tmpOut | ForEach-Object { Info $_ } }
    Remove-Item $tmpIn, $tmpOut -Force -ErrorAction SilentlyContinue
  }
  Step "receipt: winget search '$SearchTerm' from source '$SourceAlias'"
  winget search $SearchTerm --source $SourceAlias
  if ($LASTEXITCODE -ne 0) {
    Write-Host '[CLIENT_TEST_FAIL] search failed - did -Ingest run? auth mode? probe with -Verify first.' -ForegroundColor Red
    return
  }
  Write-Host "`n[CLIENT_TEST_OK] your package round-tripped: PC -> Azure repo -> PC." -ForegroundColor Green
  Write-Host "To actually install (manual, per approval):"
  Write-Host "  winget install --id <IdShownAbove> --source $SourceAlias --accept-source-agreements --accept-package-agreements"
}

# no switch given -> usage
if (-not ($Destroy -or $Deploy -or $Verify -or $GetManifest -or $Ingest -or $ClientTest)) {
  Write-Host 'No switch given. Use: -Destroy / -Deploy / -Verify / -GetManifest / -Ingest / -ClientTest (see header comment).'
}