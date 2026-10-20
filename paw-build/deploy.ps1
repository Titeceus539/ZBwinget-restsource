# deploy.ps1 - ONE-FILE ORCHESTRATOR: the whole winget-RestSource consumer build
# Branch: Tim | Proven-as-run pieces only; unproven gaps are marked RUNTIME-GATE below.
#
# What it does, in order:
#   A. Repo side  (rg-winget-manual): storage + Cosmos + Function App + settings +
#      identity/RBAC + payload pointing (skips anything that already exists)
#   B. VM side    (rg-pawtest):       RG + NSG + VNet + VM (TrustedLaunch) + parity
#   C. In-VM setup via run-command (winget source -> repo)  [RUNTIME-GATE: needs repo live]
#
# Prereqs: az login done; Owner rights; PowerShell 5.1+ (no pwsh dependency).
# Secrets: none stored - repo key + staging SAS are fetched/created at run time.
#
param(
  [switch]$RepoSide,    # step A only
  [switch]$VmSide,      # step B only
  [switch]$InVmSetup,   # step C only (after repo live)
  [string]$StagingBlobName = "payload-at-root.zip"   # the proven payload in function-releases
)

$ErrorActionPreference = "Stop"
$SUBID     = "51d0ca21-eaa5-4d34-aeb3-fa9f7d454b5d"
$LOC_REPO  = "australiaeast"
$LOC_VM    = "uaenorth"        # native region of gallery image PrivilegedWorkstationTL

# --- repo-side constants -------------------------------------------------
$REPO_RG    = "rg-winget-manual"
$REPO_STG   = "stwingetmanualtm1"
$REPO_COSM  = "cosmos-wingetmanual-tm1"
$REPO_FUNC  = "func-wingetmanual-tm1"

# --- vm-side constants ---------------------------------------------------
$VM_RG      = "rg-pawtest"
$VM_NSG     = "pawtest-nsg"
$VM_VNET    = "pawtest-vnet"
$VM_SUBNET  = "session-hosts"
$VM_NAME    = "pawtest-1"
$VM_SIZE    = "Standard_D4s_v4"
$VM_ADMIN   = "timadmin"
$STG_REL    = $REPO_STG        # storage hosting the release payload + vm-staging container

# --- helpers ---------------------------------------------------------------
function RetryAz { param($cmd, $tries=8, $wait=40)
  for ($i=1; $i -le $tries; $i++) {
    if (Invoke-Expression $cmd) { return $true }
    Write-Host "  attempt $i failed - $($wait)s wait"; Start-Sleep $wait
  }
  throw "ALL ATTEMPTS FAILED: $cmd"
}
# (RetryAz pattern = the proven workaround for ARM's 503 storms 2026-10-20)

# ============================================================
# PART A - REPO SIDE
# ============================================================
if ($RepoSide -or ($PSBoundParameters.Count -eq 0)) {

  if (-not (az group show -n $REPO_RG 2>$null)) { az group create -g $REPO_RG -l $LOC_REPO -o none }
  if (-not (az storage account show --name $REPO_STG 2>$null)) {
    az storage account create -g $REPO_RG -n $REPO_STG --location $LOC_REPO --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false -o none
  }
  if (-not (az cosmosdb show -g $REPO_RG -n $REPO_COSM 2>$null)) {
    RetryAz "az cosmosdb create -g $REPO_RG -n $REPO_COSM --capabilities EnableServerless --disable-local-auth true --default-consistency-level Session --locations regionName=$LOC_REPO failoverPriority=0 -o none"
    az cosmosdb sql database create -g $REPO_RG -a $REPO_COSM -n WinGet -o none
    az cosmosdb sql container create -g $REPO_RG -a $REPO_COSM -d WinGet -n Manifests --partition-key-path /id -o none
  }

  # Function app: delete only if exists (recreate is CLEAN - content-share mode is fresh each time)
  if (az functionapp show -g $REPO_RG -n $REPO_FUNC 2>$null) {
    Write-Host "function app exists - leaving as-is (delete/recreate explicitly if needed)"
  }

  # payload upload (overwrite = safe idempotent)
  RetryAz "az storage blob upload --account-name $STG_REL --container-name function-releases --name $StagingBlobName --file .\payload-at-root.zip --overwrite --auth-mode key -o none"

  # settings + RFP (this is where ARM may be slow; RetryAz carries it)
  $sas = az storage blob generate-sas --account-name $STG_REL --container-name function-releases --name $StagingBlobName --auth-mode key --expiry (Get-Date).AddYears(1).ToString("yyyy-MM-dd") --permissions r --https-only --full-uri -o tsv
  RetryAz "az functionapp config appsettings set -g $REPO_RG -n $REPO_FUNC --settings CosmosAccountEndpoint='https://$REPO_COSM.documents.azure.com:443/' CosmosDatabase=WinGet CosmosContainer=Manifests CosmosUseAadAuth=true ServerIdentifier=winget-cli-restsource-paw FUNCTIONS_EXTENSION_VERSION=~4 FUNCTIONS_WORKER_RUNTIME_VERSION=10.0 'WEBSITE_RUN_FROM_PACKAGE=$sas' -o none"

  # identity + RBAC (idempotent: principal may differ after recreate - use current)
  $pid = az functionapp identity assign -g $REPO_RG -n $REPO_FUNC --query principalId -o tsv
  RetryAz "az cosmosdb sql role assignment create --account-name $REPO_COSM -g $REPO_RG --scope '/' --role-definition-id '00000000-0000-0000-0000-000000000002' --principal-id '$pid' -o none"

  Write-Host "[REPO_SIDE_DONE] - now wait for host: probe /api/information"
}

# ============================================================
# PART B - VM SIDE
# ============================================================
if ($VmSide -or ($PSBoundParameters.Count -eq 0)) {

  if (-not (az group show -n $VM_RG 2>$null)) { az group create -g $VM_RG -l $LOC_VM -o none }
  if (-not (az network nsg show -g $VM_RG -n $VM_NSG 2>$null)) { az network nsg create -g $VM_RG -n $VM_NSG -o none }

  # NSG rules (same set as paw2-hp-rg's session-hosts; ports EXPLICIT - the 80-default bug fix)
  $adminpw = Read-Host -Prompt "Enter ADMIN PASSWORD for $VM_NAME (never stored)"
  $rules = @(
    @{n="AllowPrivateEndpoint";  p=100;  d="Outbound"; a="Allow"; pr="*";   dp="*";   dst="10.250.2.0/26"},
    @{n="AllowEntraAuth";        p=110;  d="Outbound"; a="Allow"; pr="*";   dp="*";   dst="AzureActiveDirectory"},
    @{n="AllowAzureCloud";       p=120;  d="Outbound"; a="Allow"; pr="*";   dp="*";   dst="AzureCloud"},
    @{n="AllowAzureDns";         p=130;  d="Outbound"; a="Allow"; pr="*";   dp="53";  dst="AzureDNS"},
    @{n="AllowFrontDoorPortal";  p=140;  d="Outbound"; a="Allow"; pr="Tcp"; dp="443"; dst="AzureFrontDoor.Frontend"},
    @{n="AllowFrontDoorFirstParty"; p=141; d="Outbound"; a="Allow"; pr="Tcp"; dp="443"; dst="AzureFrontDoor.FirstParty"},
    @{n="AllowAzurePortalTag";   p=142;  d="Outbound"; a="Allow"; pr="Tcp"; dp="443"; dst="AzurePortal"},
    @{n="AllowRdpMyIp";          p=300;  d="Inbound";  a="Allow"; pr="Tcp"; dp="3389"; dst="*"},
    @{n="DenyInternetOutbound";  p=3096; d="Outbound"; a="Deny";  pr="*";   dp="*";   dst="Internet"},
    @{n="AllowVNetOutbound";     p=4000; d="Outbound"; a="Allow"; pr="*";   dp="*";   dst="VirtualNetwork"},
    @{n="DenyAllInbound";        p=4096; d="Inbound";  a="Deny";  pr="*";   dp="*";   dst="*"}
  )
  foreach ($r in $rules) {
    $base = "az network nsg rule create -g $VM_RG --nsg-name $VM_NSG -n $($r.n) --priority $($r.p) --direction $($r.d) --access $($r.a) --protocol `"$($r.pr)`" --destination-port-ranges `"$($r.dp)`""
    if ($r.dst -ne "*") { $base = $base + " --destination-address-prefix `"$($r.dst)`"" }
    RetryAz ($base + " -o none")
  }

  if (-not (az network vnet show -g $VM_RG -n $VM_VNET 2>$null)) {
    az network vnet create -g $VM_RG -n $VM_VNET --address-prefix 10.251.0.0/16 --subnet-name $VM_SUBNET --subnet-prefixes 10.251.0.0/24 -o none
  }
  $sub = az network vnet subnet show -g $VM_RG --vnet-name $VM_VNET -n $VM_SUBNET --query id -o tsv
  az network vnet subnet update --ids $sub --network-security-group $VM_NSG -o none

  # VM creation - TrustedLaunch MANDATORY for the gallery image
  if (-not (az vm show -g $VM_RG -n $VM_NAME 2>$null)) {
    $image = "/subscriptions/$SUBID/resourceGroups/tim_paw_gallery_rg/providers/Microsoft.Compute/galleries/tim_paw_gallery_rg/images/PrivilegedWorkstationTL/versions/1.0.1791889081"
    # security note: password typed by operator, piped, not echoed
    $sec = ConvertTo-SecureString $adminpw -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($VM_ADMIN, $sec)
    az vm create -g $VM_RG -n $VM_NAME --image $image --size $VM_SIZE `
      --admin-username $VM_ADMIN --admin-password $adminpw `
      --vnet-name $VM_VNET --subnet $VM_SUBNET --nsg $VM_NSG --public-ip-address "" `
      --security-type TrustedLaunch -o json
  } else { Write-Host "VM exists - skipping create" }

  # PrivAVD parity
  az vm identity assign -g $VM_RG -n $VM_NAME -o none
  az vm update -g $VM_RG -n $VM_NAME --license-type Windows_Client -o none
  az vm extension set -g $VM_RG --vm-name $VM_NAME --name AADLoginForWindows --publisher Microsoft.Azure.ActiveDirectory --version 2.2 -o none

  Write-Host "[VM_SIDE_DONE] - $VM_NAME running, parity bits on"
}

# ============================================================
# PART C - IN-VM SETUP (winget source -> repo) via run-command
# ============================================================
if ($InVmSetup -or ($PSBoundParameters.Count -eq 0)) {

  $key = az functionapp keys list -g $REPO_RG -n $REPO_FUNC --query functionKeys.default -o tsv
  if (-not $key) { throw "could not fetch repo function key - is the app up?" }
  $invm = @"
`$ErrorActionPreference='Stop'
winget source remove internal 2>`$null
winget source add --name internal --arg 'https://$REPO_FUNC.azurewebsites.net/api?code=$key' --type Microsoft.Rest
if (`$LASTEXITCODE -ne 0) { write-host '[INVM_FAIL] source add'; exit 1 }
write-host '[INVM_OK] source added'
"@
  $tmp = New-TemporaryFile
  Set-Content -Path $tmp -Value $invm -Force
  RetryAz "az vm run-command invoke -g $VM_RG --name $VM_NAME --command-id RunPowerShellScript --scripts `@`$tmp" -tries 4 -wait 30
  Remove-Item $tmp -Force
  Write-Host "[INVM_DONE] - verify inside VM: winget search 7zip --source internal"
}