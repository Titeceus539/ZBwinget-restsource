# BUILD JOURNAL — winget-restsource (owner-approved log; every change recorded)

## 2026-10-20

- [F1] `setup-pawtest-vm.ps1` line 35: PG download 18.10-1 → **18.6-1** (18.10-1 = 403 dead; 18.6-1 verified 200)
- Created **rg-winget-manual** contents by hand:
  - `stwingetmanualtm1` (StorageV2 LRS, https-only, TLS1.2, no public blob access)
    - container `function-releases`: `payload-at-root.zip` (47,819,629 B) = old app's LIVE payload + `site/wwwroot/` prefix stripped (host needs files at zip root)
    - container `vm-staging` (private): PG 18.6-1 (343,808,005 B), 7z2604-x64.exe (1,664,082 B, hash d54bf805… == manifest pin), AK zip (40,207,173 B)
  - `cosmos-wingetmanual-tm1` (serverless, disable-local-auth, db **WinGet**, container **Manifests**, partition /id)
  - `func-wingetmanual-tm1` (Consumption Y1, dotnet-isolated, runtime **10** — v1 was deleted: wrong 8 + wedged content-share/package dual-mode)
  - identity `890bd03b-92f9-4126-9564-e2f2e6decb2c` + Cosmos RBAC "Built-in Data Contributor" @ "/" granted
  - app settings: Cosmos trio + CosmosUseAadAuth=true + ServerIdentifier + WEBSITE_RUN_FROM_PACKAGE=<SAS payload-at-root.zip>
- KEY FINDING: old repo's "anonymous reads" = per-function `function.json` (authLevel Anonymous) **hand-patched into deployed wwwroot** on 10-15; local zips DON'T ship them; recovered via Kudu `/api/zip`; InformationGet/ManifestGet/ManifestSearchPost = Anonymous
- KEY FINDING: `az … config appsettings` via Kudu POST broken from this host (HTTP 000); ARM 503 storms all day; working combo = ARM retry-loops + Kudu GET reads
- BLOCKERS remaining: ARM/Kudu outage waves; host not yet restarted successfully post-payload-swap (watcher pattern)
- `rg-pawtest` created (UAE North): pawtest-nsg (same rule-set as paw2-hp), pawtest-vnet (10.251.0.0/16, session-hosts subnet), VM **pawtest-1** D4s_v4, TrustedLaunch, image PrivilegedWorkstationTL 1.0.1791889081, admin timadmin, NO public IP
- `setup-winget-consumer-vm.ps1` migrated to `D:\code\ZBwinget-restsource` **branch Tim**, commit "Migrated consumer-VM setup script (fixes F1-F4 applied, AK parked)"
- SCOPE (owner): NO PrivAVD/PAW integration now; AK parked; focus winget RestSource; new VM same recipe different location; ALL script fixes go onto branch Tim
- pawtest-1 credentials: `staging\pawtest-1.credentials.txt` (local only, chmod 600)