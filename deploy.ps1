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
  -Repair                               re-run the post-deploy repair standalone
                                        (use after a deploy that errored at the module's
                                        final Cosmos-role-assignment step)
  -Verify                               read-only: discover + probe the endpoint
  -GetManifest -PackageId <id> [-Version <v>]
                                        pull one manifest version from microsoft/winget-pkgs
                                        into .\manifests\<id>\<v>\; use -Version list to list
  -Ingest -ManifestDir <dir>            push that folder into the repo (Add-WinGetManifest)
  -ClientTest [-SearchTerm <term>]      add winget source 'internal' (auto-elevates via
                                        UAC if needed) + winget search receipt
  -Publish -File <path> -PackageId <id> -Version <v> -Publisher <pub>
                                        ONE-LINE self-hosted publish: uploads the exe to
                                        your installers blob container, signs a link,
                                        builds the manifest triplet, ingests it. Use for
                                        files NOT in the public catalog.
  -List                                 what's in the repo? (table: id, version, name, file)
  -Fetch -PackageId <id> -Version <v> [-OutDir <dir>]
                                        download a published installer back out of the
                                        repo, hash-verified (default dir .\downloads)

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
  [switch]$Repair,
  [switch]$Verify,
  [switch]$GetManifest,
  [switch]$Ingest,
  [switch]$ClientTest,
  [switch]$Publish,
  [switch]$List,
  [switch]$Fetch,
  [string]$OutDir,
  [string]$PackageId,
  [string]$Version,
  [string]$ManifestDir,
  [string]$File,
  [string]$Publisher,
  [string]$Description,
  [ValidateSet('x86', 'x64', 'arm64')]
  [string]$Architecture = 'x64',
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
  $appRaw   = az functionapp list -g $RG --query '[0].{name:name, host:defaultHostName}' -o json 2>&1
  $cosmosRaw = az cosmosdb list -g $RG --query '[0].name' -o tsv 2>&1
  if ("$appRaw $cosmosRaw" -match 'AuthorizationFailed') {
    throw "AuthorizationFailed - your Azure role (PIM Owner) is not active right now. Activate Owner in the portal (Entra -> PIM -> Activate), then run the same command again. Nothing else is wrong."
  }
  $app    = ($appRaw -join "`n") | ConvertFrom-Json -ErrorAction SilentlyContinue
  $cosmos = ("$cosmosRaw" -split "`n")[0].Trim()
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
  $didRepair = $false
  $dis = (az cosmosdb show -g $RG -n $r.Cosmos --query disableLocalAuth -o tsv) -eq 'true'
  if ($dis) {
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
    Info 'cosmos app settings set'
    $didRepair = $true
  } else { Info 'cosmos accepts key auth - module wiring intact, no repair needed' }

  # v1.10.1 module bug: it throws at the Cosmos role-assignment step (GUID passed as RG
  # name) BEFORE publishing the function code -> app exists but is empty (404 on /api/*).
  # Repair: if no functions are deployed, publish the module's own stock zip.
  $fnNames = @(az functionapp function list -g $RG -n $r.App.name --query "[].name" -o tsv 2>$null) | Where-Object { $_ -match '\S' }
  if ($fnNames.Count -eq 0) {
    $mod = Get-Module Microsoft.WinGet.RestSource -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    $zip = Join-Path $mod.ModuleBase 'Data\WinGet.RestSource.Functions.zip'
    if (-not (Test-Path -LiteralPath $zip)) { throw "module stock zip not found: $zip" }
    Info "function app has no code - publishing module stock zip ($(('{0:N1}' -f ((Get-Item $zip).Length / 1MB))) MB)"
    Import-Module Az.Websites -ErrorAction Stop
    Publish-AzWebApp -ArchivePath $zip -ResourceGroupName $RG -Name $r.App.name -Force -ErrorAction Stop | Out-Null
    $didRepair = $true
    Info 'code published'
  } else { Info "code present ($($fnNames.Count) functions) - no publish needed" }

  if ($didRepair) {
    az functionapp restart -g $RG -n $r.App.name -o none
    Info 'restarted (RBAC may take ~10 min to propagate - the probe waits for it)'
  }
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
  Info 'NOTE: the module may throw at its LAST step (Cosmos role assignment passes a GUID as a resource-group name - v1.10.1 bug).'
  Info '      If resources are all built and ONLY that failed -> run: .\deploy.ps1 -Repair, then .\deploy.ps1 -Verify'
  try {
    $ok = New-WinGetSource @sourceSettings
    if (-not $ok) { throw 'New-WinGetSource reported failure.' }
  } catch {
    $r = $null
    try { $r = Get-RepoResources } catch { }
    if ($r) {
      Write-Host '[MODULE_THREW_AFTER_BUILD] resources exist - switching to -Repair path' -ForegroundColor Yellow
      Set-RepoRepair | Out-Null
      if (-not (Test-RepoHealth)) { throw 'endpoint did not come healthy after repair - see probe output.' }
      Write-Host "`n[DEPLOY_DONE] (module errored at final wiring; repair completed it) Next: -GetManifest -> -Ingest -> -ClientTest" -ForegroundColor Green
      return
    }
    throw 'New-WinGetSource failed before resources existed - nothing to repair. See output above.'
  }

  Set-RepoRepair | Out-Null
  if (-not (Test-RepoHealth)) { throw 'endpoint did not come healthy after deploy - see probe output.' }
  Write-Host "`n[DEPLOY_DONE] repo is live. Next: -GetManifest -> -Ingest -> -ClientTest" -ForegroundColor Green
}

# ============================================================= -Repair
if ($Repair) {
  Ensure-Az
  Set-RepoRepair | Out-Null
  if (-not (Test-RepoHealth)) { throw 'endpoint did not come healthy after repair - see probe output.' }
  Write-Host "[REPAIR_DONE] repo healthy." -ForegroundColor Green
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
  # GitHub winget-pkgs paths are CASE-SENSITIVE: letter folder LOWERCASE, pub/prod mirror
  # the ID exactly (7zip.7zip -> 7/7zip/7zip, PuTTY.PuTTY -> p/PuTTY/PuTTY).
  $letter = "$($pub[0])".ToLower()
  $ghFolder = "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/$letter/$pub/$prod"
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

# ============================================================= -Publish
# One-line self-hosted publish: upload exe -> signed link -> manifest triplet -> ingest.
# Exists because wingetcreate cannot parse signed blob URLs (uses the querystring as a
# filename) - so the manifest build is done here deterministically, spec 1.12.0 (the
# exact spec proven live on this repo 2026-10-21 with the 7-Zip ingestion).
function New-PublishManifest {
  param([string]$File, [string]$Id, [string]$Ver, [string]$Pub, [string]$Desc, [string]$Arch, [string]$Url, [string]$Sha)
  $dir = Join-Path $PSScriptRoot "manifests\$Id\$Ver"
  New-Item -ItemType Directory -Path $dir -Force | Out-Null

  $verY = @"
PackageIdentifier: $Id
PackageVersion: '$Ver'
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.12.0
"@

  $safeDesc = if ($Desc) { $Desc } else { "Package $Id" }
  $localeY = @"
PackageIdentifier: $Id
PackageVersion: '$Ver'
PackageLocale: en-US
Publisher: $Pub
PackageName: $(($Id -split '\.')[-1])
License: Proprietary
ShortDescription: $safeDesc
ManifestType: defaultLocale
ManifestVersion: 1.12.0
"@

  $instY = @"
PackageIdentifier: $Id
PackageVersion: '$Ver'
InstallerType: portable
InstallModes:
- interactive
- silent
- silentWithProgress
ReleaseDate: $(Get-Date -Format yyyy-MM-dd)
Installers:
- Architecture: $Arch
  InstallerUrl: $Url
  InstallerSha256: $Sha
ManifestType: installer
ManifestVersion: 1.12.0
"@

  Set-Content -Path (Join-Path $dir "$Id.yaml") -Value $verY -Encoding utf8NoBOM
  Set-Content -Path (Join-Path $dir "$Id.locale.en-US.yaml") -Value $localeY -Encoding utf8NoBOM
  Set-Content -Path (Join-Path $dir "$Id.installer.yaml") -Value $instY -Encoding utf8NoBOM
  return $dir
}

if ($Publish) {
  Step 'PUBLISH (upload -> link -> manifest -> ingest)'
  foreach ($req in @(
    @{ v = $File;          n = '-File <path to the .exe>' },
    @{ v = $PackageId;     n = '-PackageId <Publisher.Product, e.g. Zenblox.MyApp>' },
    @{ v = $Version;       n = '-Version <e.g. 1.0.0>' },
    @{ v = $Publisher;     n = '-Publisher <e.g. Zenblox>' }
  )) { if (-not $req.v) { throw "need $($req.n)" } }
  if (-not (Test-Path -LiteralPath $File)) { throw "-File not found: '$File'" }
  Ensure-Az
  $r = Get-RepoResources

  # Discover the storage account from the function app's own wiring - never hardcode it,
  # so this works for every dev's settings file and survives rebuilds/renames.
  $blobUri = az functionapp config appsettings list -g $RG -n $r.App.name --query "[?name=='AzureWebJobsStorage__blobServiceUri'].value" -o tsv
  $stg = if ($blobUri) { ([uri]$blobUri).Host.Split('.')[0] } else { 'st' + (([string]$settings.Name).ToLower() -replace '[^a-z0-9]', '') }
  Info "storage account: $stg"

  # 1. ensure the installers container exists (fail LOUDLY with the role hint)
  $mk = az storage container create --account-name $stg --name installers --public-access off --auth-mode login -o none 2>&1
  if ($LASTEXITCODE -ne 0 -and ("$mk" -notmatch 'already exists|AlreadyExists')) {
    throw "cannot create container 'installers' on $stg. You likely need Storage Blob Data Owner on that storage account (portal: storage account -> Access control (IAM) -> Add role assignment). az said: $mk"
  }

  # 2. upload (blob name = the file's real name; --overwrite makes re-publish silent)
  $blobName = [IO.Path]::GetFileName($File)
  Info "uploading $blobName ..."
  az storage blob upload --account-name $stg --container-name installers --name $blobName --file $File --overwrite --auth-mode login -o none
  if ($LASTEXITCODE -ne 0) { throw "blob upload failed (see az output above)" }
  Info 'uploaded'

  # 3. hash the LOCAL file (identical to the blob by upload contract, re-read local)
  $sha = (Get-FileHash -Path $File -Algorithm SHA256).Hash
  Info "sha256: $sha"

  # 4. signed link, pinned pattern (user-delegation SAS: --as-user, 7-day cap)
  $expiry = (Get-Date).AddDays(6).ToString('yyyy-MM-dd')
  $url = az storage blob generate-sas --account-name $stg --container-name installers --name $blobName --permissions r --expiry $expiry --https-only --as-user --auth-mode login --full-uri -o tsv
  if (-not $url -or $url -notmatch '^https://') { throw "SAS generation failed: '$url'" }
  Info "signed link until $expiry"

  # 5. manifest triplet
  $dir = New-PublishManifest -File $File -Id $PackageId -Ver $Version -Pub $Publisher -Desc $Description -Arch $Architecture -Url $url -Sha $sha
  Info "manifest files in $dir"

  # 6. straight into the proven ingest (module warns per app-setting property - suppress that spray only)
  Import-Module Microsoft.WinGet.RestSource -ErrorAction Stop
  $warnBefore = $WarningPreference
  $WarningPreference = 'SilentlyContinue'
  try { Add-WinGetManifest -FunctionName $r.App.name -Path $dir } finally { $WarningPreference = $warnBefore }
  Write-Host "`n[PUBLISH_OK] '$PackageId' $Version live from your blob." -ForegroundColor Green
  Write-Host "Install on any wired PC:"
  Write-Host "  winget install --id $PackageId --version $Version --source internal --accept-package-agreements --accept-source-agreements"
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

# ============================================================= -List
# What is in the repo?  Read-only, no Azure writes.
if ($List) {
  Ensure-Az
  $r = Get-RepoResources
  $k = az functionapp keys list -g $RG -n $r.App.name --query functionKeys.default -o tsv
  if (-not $k) { throw 'could not read the repo function key' }
  $resp = Invoke-RestMethod -Uri "$($r.Url)/packageManifests?code=$k" -TimeoutSec 60
  if (-not $resp.Data) { Write-Host '[REPO_EMPTY] nothing published yet - use -Publish'; return }
  $rows = foreach ($p in $resp.Data) {
    foreach ($v in $p.Versions) {
      [pscustomobject]@{
        PackageIdentifier = $p.PackageIdentifier
        Version           = $v.PackageVersion
        Name              = $v.DefaultLocale.PackageName
        Publisher         = $v.DefaultLocale.Publisher
        File              = [IO.Path]::GetFileName(([uri](($v.Installers | Select-Object -First 1).InstallerUrl)).AbsolutePath)
      }
    }
  }
  $rows | Sort-Object PackageIdentifier, Version | Format-Table -AutoSize
  Write-Host ("[LIST_OK] {0} package(s) in the repo" -f @($resp.Data).Count) -ForegroundColor Green
}

# ============================================================= -Fetch
# Download a published installer back out of the repo, hash-verified. For devs who want
# the file itself rather than an install. -OutDir defaults to .\downloads
if ($Fetch) {
  if (-not $PackageId -or -not $Version) { throw 'need -PackageId and -Version for -Fetch (run -List to see what exists)' }
  Ensure-Az
  $r = Get-RepoResources
  $k = az functionapp keys list -g $RG -n $r.App.name --query functionKeys.default -o tsv
  if (-not $k) { throw 'could not read the repo function key' }
  $resp = Invoke-RestMethod -Uri "$($r.Url)/packageManifests?code=$k" -TimeoutSec 60
  $pkg = @($resp.Data) | Where-Object PackageIdentifier -eq $PackageId
  if (-not $pkg) { throw "package '$PackageId' not in the repo - run -List" }
  $ver = @($pkg.Versions) | Where-Object PackageVersion -eq $Version
  if (-not $ver) { throw "'$PackageId' has no version '$Version' - run -List" }
  $inst = @($ver.Installers)[0]
  if (-not $inst.InstallerUrl) { throw 'manifest has no installer URL' }
  $outDir = if ($OutDir) { $OutDir } else { Join-Path $PSScriptRoot 'downloads' }
  New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  $fileName = [IO.Path]::GetFileName(([uri]$inst.InstallerUrl).AbsolutePath)
  $target = Join-Path $outDir $fileName
  Step "FETCH $PackageId $Version -> $target"
  Invoke-WebRequest -Uri $inst.InstallerUrl -OutFile $target -TimeoutSec 600
  $got = (Get-FileHash -Path $target -Algorithm SHA256).Hash.ToUpper()
  $want = ([string]$inst.InstallerSha256).ToUpper()
  if ($got -ne $want) {
    Remove-Item $target -Force -ErrorAction SilentlyContinue
    throw "HASH MISMATCH - download rejected and deleted. got $got / manifest says $want"
  }
  Write-Host "[FETCH_OK] $fileName  sha256 verified ($got)" -ForegroundColor Green
  Write-Host "  saved: $target"
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
if (-not ($Destroy -or $Deploy -or $Repair -or $Verify -or $GetManifest -or $Ingest -or $List -or $Fetch -or $ClientTest -or $Publish)) {
  Write-Host 'No switch given. Use: -Destroy / -Deploy / -Repair / -Verify / -List / -Fetch / -GetManifest / -Publish / -Ingest / -ClientTest (see header comment).'
}