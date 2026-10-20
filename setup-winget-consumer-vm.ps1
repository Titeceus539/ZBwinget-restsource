# setup-winget-consumer-vm.ps1 — install winget-source config INTO the PAW-test VM
# Target: pawtest-1 (rg-pawtest, UAE North) — built from gallery image PrivilegedWorkstationTL.
# AK + PostgreSQL deliberately NOT installed (parked per owner decision 2026-10-20; the
# AK-ready hooks remain as comments so re-enabling is a copy-paste, not a redesign).
# Fixes vs the original setup-pawtest-vm.ps1 (all proven live 2026-10-20):
#   [F1] PG 18.6-1  = live EDB version; 18.10-1 URL is dead (403). PG now pulled from vm-staging blob anyway.
#   [F2] All VM downloads come from the private vm-staging blob (NSG 3096 denies plain Internet).
#   [F3] run-command flag = --name (this az CLI rejects --vm-name).
#   [F4] New repo URL = rg-winget-manual / func-wingetmanual-tm1 key injected at run time.
# Logs: C:\setup\. Ends with [SETUP_OK] or [SETUP_FAIL].

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
New-Item -ItemType Directory -Path "C:\setup" -Force | Out-Null
Start-Transcript -Path "C:\setup\setup-transcript.txt" -Append

function OK($m)  { Write-Host "[OK] $m" -ForegroundColor Green }
function FAIL($m){ Write-Host "[SETUP_FAIL] $m" -ForegroundColor Red; Stop-Transcript; exit 1 }

# ===== INSERTED AT RUN TIME by the orchestrator (not stored in git): =====
#   $REPO_URL = "https://func-wingetmanual-tm1.azurewebsites.net/api?code=<key>"
#   $STG_SAS  = "<container-SAS for vm-staging>"
#   $AK_LATER = $true   # parked: run the commented AK section when re-enabled
# =========================================================================

try { $null = winget --version; OK "winget client: $(winget --version)" }
catch { FAIL "winget client missing (image should ship it - investigate image)" }

$src = winget source list 2>$null | Select-String "internal"
if (-not $src) {
    winget source add --name internal --arg "$REPO_URL" --type Microsoft.Rest 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) { FAIL "winget source add failed (exit $LASTEXITCODE)" }
    OK "winget source 'internal' -> NEW repo"
} else { OK "winget source 'internal' already present" }

if (-not $STG_SAS) { FAIL "vm-staging SAS not provided - aborting before any download" }

# [AK-PARKED] PostgreSQL + Artifact Keeper install block (re-enable by setting AK_LATER=$true):
<#
$pgZip = "C:\setup\postgresql-18.6-1-windows-x64-binaries.zip"
Invoke-WebRequest -Uri "https://stwingetmanualtm1.blob.core.windows.net/vm-staging/postgresql-18.6-1-windows-x64-binaries.zip$STG_SAS" -OutFile $pgZip -TimeoutSec 900
... (original sections 3-5 of setup-pawtest-vm.ps1, unchanged, kept in git history) ...
#>

Write-Host "`n[SETUP_OK] winget source added. PG+AK parked per owner decision 2026-10-20." -ForegroundColor Green
Write-Host "Next: RDP in, run 'winget search 7zip --source internal'"
Stop-Transcript