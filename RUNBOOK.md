# RUNBOOK — Operating the Winget Repo

Private winget repo on Azure (function app + Cosmos). One script does everything:
`deploy.ps1`. Settings live in `deploy-settings.psd1` (gitignored — real IDs).

User-facing how-to (publish/install packages) = **USERS.md**. This file is for
operating and rebuilding the repo itself.

---

## Commands

```powershell
cd D:\code\ZBwinget-restsource\ZBwinget-restsource   # branch Tim
az login                                             # once per session

.\deploy.ps1 -Deploy      # build the whole repo (~15 min) + auto-repair + wait until healthy
.\deploy.ps1 -Verify      # is the repo alive?   receipt: [HOST_UP]
.\deploy.ps1 -Repair      # finish a deploy the module abandoned (safe to re-run)
.\deploy.ps1 -Destroy     # delete EVERYTHING (asks you to type the RG name)
.\deploy.ps1 -GetManifest -PackageId <id> -Version list|<v>   # pull manifests from GitHub
.\deploy.ps1 -Ingest -ManifestDir .\manifests\<id>\<v>        # push manifest into the repo
.\deploy.ps1 -ClientTest  # wire this PC's winget to the repo (UAC prompt = normal)
pwsh ./scripts/verify-loop.ps1   # read-only health check, receipt: 6/6 PASS
```

## The two rules

1. **`-Destroy` deletes the entire resource group in settings.** That group must
   contain only the repo. Protected groups (rg-winget-manual, rg-pawtest,
   paw2-hp-rg, galleries, paw2*/pawtest*) are hardcoded-refused — keep it that way.
2. **A rebuild forgets all packages.** After `-Destroy` + `-Deploy`, re-publish
   each package (USERS.md step 2). By design.

## Known module bugs (scripted around, don't hand-fix)

- Module v1.10.1 aborts at its final Cosmos role-assignment step (GUID-as-RG-name bug)
  → repo builds but code never publishes. `deploy.ps1` catches this and auto-repairs
  (identity + RBAC + stock-zip publish + restart). Manual fallback: `-Repair`.
- Deployed Cosmos has no identity wiring → 500s. Repair handles it automatically.

## If it breaks

| Symptom | Do |
|---|---|
| Deploy errors mentioning Cosmos role assignment | `.\deploy.ps1 -Repair` then `-Verify` |
| Deploy fails with a name-collision error | Change `Name` in `deploy-settings.psd1`, rerun `-Destroy` → `-Deploy` — names must be globally unique across Azure |
| `/api/information` 503 for ages | Function genuinely erroring: `az functionapp log tail -g tm-winget-rg -n func-TmWinget2`. 503 ≠ up; only `-Verify` says `[HOST_UP]` |
| `az` says AuthorizationFailed | Re-run `az login`; check Owner role on the subscription |

## History / status

Journal files: `build-journal-YYYY-MM-DD.md`, newest date first = current truth.