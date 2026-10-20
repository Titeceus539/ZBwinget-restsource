# build-pawtest-rg.ps1 - build the PAW-consumer resource group: RG + NSG + VNet + VM
# Proven-as-run 2026-10-20 (the live commands that created rg-pawtest / pawtest-1,
# captured into a script per owner's log rule). Idempotent-ish: names are fixed,
# re-run on an existing group will error on create - check first with the LIST at bottom.
#
# Recipe source: paw2-hp-rg (PrivAVD deployPaw session-host shape), new location,
# same NSG egress discipline, same gallery image version, TrustedLaunch required
# (discovered live: the gallery image refuses non-TrustedLaunch VMs).
#
# Prereqs: az login (Zenme Azure 1); Owner rights; image version still replicated.
#
# --- knobs ---------------------------------------------------------------
$RG        = "rg-pawtest"
$LOCATION  = "uaenorth"          # different from paw2-hp-rg (centralindia), native to the image
$NSG       = "pawtest-nsg"
$VNET      = "pawtest-vnet"
$ADDRANGE  = "10.251.0.0/16"     # fresh space - must not overlap paw2-hp's 10.250.x
$SUBNET    = "session-hosts"
$SUBPREFIX = "10.251.0.0/24"
$VM        = "pawtest-1"
$VMSIZE    = "Standard_D4s_v4"
$ADMIN     = "timadmin"
$SUBID     = "51d0ca21-eaa5-4d34-aeb3-fa9f7d454b5d"
$IMAGE     = "/subscriptions/$SUBID/resourceGroups/tim_paw_gallery_rg/providers/Microsoft.Compute/galleries/tim_paw_gallery_rg/images/PrivilegedWorkstationTL/versions/1.0.1791889081"
# admin password: pass in via -AdminPassword (never store in this file)
param(
  [Parameter(Mandatory=$true)] [string]$AdminPassword
)

$ErrorActionPreference = "Stop"

# --- 1. resource group ---------------------------------------------------
az group create -g $RG -l $LOCATION -o none

# --- 2. NSG with the paw2-hp rule set ------------------------------------
az network nsg create -g $RG -n $NSG -o none
# note: each rule's --destination-port-ranges defaults were WRONG when omitted
# during the live build (landed as "80"); every rule now sets its ports explicitly.
az network nsg rule create -g $RG --nsg-name $NSG -n AllowPrivateEndpoint --priority 100 `
  --direction Outbound --access Allow --protocol "*" --destination-port-ranges "*" `
  --destination-address-prefix "10.250.2.0/26" -o none        # paw2-hp PE range, for the PE phase
az network nsg rule create -g $RG --nsg-name $NSG -n AllowEntraAuth --priority 110 `
  --direction Outbound --access Allow --protocol "*" --destination-port-ranges "*" `
  --destination-address-prefix AzureActiveDirectory -o none
az network nsg rule create -g $RG --nsg-name $NSG -n AllowAzureCloud --priority 120 `
  --direction Outbound --access Allow --protocol "*" --destination-port-ranges "*" `
  --destination-address-prefix AzureCloud -o none
az network nsg rule create -g $RG --nsg-name $NSG -n AllowAzureDns --priority 130 `
  --direction Outbound --access Allow --protocol "*" --destination-port-ranges 53 `
  --destination-address-prefix AzureDNS -o none
az network nsg rule create -g $RG --nsg-name $NSG -n AllowFrontDoorPortal --priority 140 `
  --direction Outbound --access Allow --protocol Tcp --destination-port-ranges 443 `
  --destination-address-prefix AzureFrontDoor.Frontend -o none
az network nsg rule create -g $RG --nsg-name $NSG -n AllowFrontDoorFirstParty --priority 141 `
  --direction Outbound --access Allow --protocol Tcp --destination-port-ranges 443 `
  --destination-address-prefix AzureFrontDoor.FirstParty -o none
az network nsg rule create -g $RG --nsg-name $NSG -n AllowAzurePortalTag --priority 142 `
  --direction Outbound --access Allow --protocol Tcp --destination-port-ranges 443 `
  --destination-address-prefix AzurePortal -o none
az network nsg rule create -g $RG --nsg-name $NSG -n AllowRdpMyIp --priority 300 `
  --direction Inbound --access Allow --protocol Tcp --destination-port-ranges 3389 -o none
az network nsg rule create -g $RG --nsg-name $NSG -n DenyInternetOutbound --priority 3096 `
  --direction Outbound --access Deny --protocol "*" --destination-port-ranges "*" `
  --destination-address-prefix Internet -o none
az network nsg rule create -g $RG --nsg-name $NSG -n AllowVNetOutbound --priority 4000 `
  --direction Outbound --access Allow --protocol "*" --destination-port-ranges "*" `
  --destination-address-prefix VirtualNetwork -o none
az network nsg rule create -g $RG --nsg-name $NSG -n DenyAllInbound --priority 4096 `
  --direction Inbound --access Deny --protocol "*" --destination-port-ranges "*" -o none

# --- 3. vnet + subnet + NSG attach ---------------------------------------
az network vnet create -g $RG -n $VNET --address-prefix $ADDRANGE `
  --subnet-name $SUBNET --subnet-prefixes $SUBPREFIX -o none
$SUBID_R = az network vnet subnet show -g $RG --vnet-name $VNET -n $SUBNET --query id -o tsv
az network vnet subnet update --ids $SUBID_R --network-security-group $NSG -o none

# --- 4. the VM (TrustedLaunch MANDATORY for this gallery image) -----------
az vm create -g $RG -n $VM --image $IMAGE --size $VMSIZE `
  --admin-username $ADMIN --admin-password $AdminPassword `
  --vnet-name $VNET --subnet $SUBNET --nsg $NSG --public-ip-address "" `
  --security-type TrustedLaunch -o json

# --- 5. PrivAVD parity bits (what deployPaw's Terraform also gives) ------
az vm identity assign -g $RG -n $VM -o none                        # system identity
az vm update -g $RG -n $VM --license-type Windows_Client -o none   # correct client licensing
az vm extension set -g $RG --vm-name $VM --name AADLoginForWindows `
  --publisher Microsoft.Azure.ActiveDirectory --version 2.2 -o none

# --- 6. verify -------------------------------------------------------------
az vm show -g $RG -n $VM --query "{name:name, state:instanceView.statuses[1].displayStatus}" -d -o json
az network nsg rule list -g $RG --nsg-name $NSG -o tsv --query "sort_by(@, &priority)[].{p:priority, n:name, dp:destinationPortRange, dst:destinationAddressPrefix}"

Write-Host "built: RG=$RG VM=$VM NSG=$NSG vnet=$VNET (location $LOCATION)"