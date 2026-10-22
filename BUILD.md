# BUILD — the winget repo from zero

Everything needed to go from **nothing in Azure** to a working private winget repo.
Daily usage (publish / install) lives in **USERS.md** — this file is build + operate.

---

## What you are building

```
your PC ──publish──▶  Azure Function App (serverless API, keyed)
                              │
                              ├── Cosmos DB  (package manifests)
                              └── Blob storage (installer files, 7-day signed links)
                                            │
any Windows PC ◀──install── winget ─────────┘   (hash-verified on download)
```

| Component | Name pattern | Purpose | Cost |
|---|---|---|---|
| Function App (consumption) | `func-<Name>` | the repo API winget talks to | ~free at our volume |
| Cosmos DB (serverless/free) | `WinGet` → `Manifests` | one record per package+version | free tier |
| Storage account | `st<name>` | installer blobs, container `installers` | pennies |
| Key Vault, App Config, App Insights, Log Analytics, App Service plan | module-created | supporting cast | negligible |

Realistic total: **single-digit dollars per month**. The repo is *serverless* in the
sense that matters — nothing runs (and nothing bills) while idle.

---

## 0. Prerequisites (one-time, on the build PC)

| Need | Check |
|---|---|
| PowerShell **7.4+** | `pwsh -v` |
| Azure CLI, logged in | `az version` |
| Az PowerShell module | `pwsh -c "Get-Module -ListAvailable Az.Accounts"` |
| `Microsoft.WinGet.RestSource` module | auto-installed by the script if missing |
| **Owner** on the subscription — via **PIM activation** | portal → Entra → PIM → activate Owner |
| **Storage Blob Data Owner** on the storage account (for publishing) | granted once per account, permanent |
| Git + this repo on branch `Tim` | `git status` |

> **PIM is the #1 source of "my roles vanished"**: Owner here is *eligible*, not permanent.
> It expires on a timer. Any `AuthorizationFailed` mid-work = re-activate in the portal
> and rerun the same command. Nothing is broken.

## 1. Settings (the only file you edit)

```powershell
cd D:\code\ZBwinget-restsource\ZBwinget-restsource
copy deploy-settings.psd1.example deploy-settings.psd1
notepad deploy-settings.psd1
```

Five required fields:

| Field | Meaning |
|---|---|
| `TenantId` | your Entra tenant GUID |
| `SubscriptionId` | subscription GUID |
| `Name` | seeds every resource name (`st<name>`, `func-<Name>`). Must be globally unique in Azure. |
| `ResourceGroup` | **dedicated** group — `-Destroy` deletes *everything* in it. Never point this at a group holding other work. |
| `Region` | e.g. `australiaeast` |

`deploy-settings.psd1` is **gitignored on purpose** (real IDs never land in git).
The rest of the file is legacy module settings — leave them alone.

## 2. Build it

```powershell
az login                      # browser popup, sign in
.\deploy.ps1 -Deploy          # ~15 minutes
```

`-Deploy` does: resource group → 10 Azure resources → identity wiring → RBAC →
**auto-repair** → wait until the host answers. Expect it to *look* stalled during
Cosmos provisioning; that is normal.

**Success receipt:** `[DEPLOY_DONE]`, then `[HOST_UP]`. If you instead see a 404 from the
function app afterwards, that is module bug #2 (below) — `-Repair` finishes it.

## 3. Verify the build (read-only, 30 s)

```powershell
pwsh ./scripts/verify-loop.ps1     # receipt: 6 passed, 0 failed
.\deploy.ps1 -Verify               # receipt: [HOST_UP]
```

`401 Unauthorized` from the API is **success** — the host is alive and the endpoints
are key-locked. Only 5xx is failure.

## 4. Publish your first package

```powershell
.\deploy.ps1 -Publish -File "C:\Users\User\winget-demo\ZB-DemoApp.exe" `
    -PackageId Zenblox.DemoApp -Version 1.0.0 -Publisher Zenblox -Description "demo app"
```
→ `[PUBLISH_OK]`. See USERS.md for the catalog-app path.

## 5. Wire the build PC as a client

```powershell
.\deploy.ps1 -ClientTest      # UAC popup → Yes
winget search --source internal
```

## 6. Publish permissions (per person, once)

Publishing needs a **data-plane role** on the storage account — Owner does **not**
include it. Portal → storage account → **Access control (IAM)** → *Add role assignment*
→ **Storage Blob Data Owner** → your account. Permanent, not PIM.

Storage rules on this account (non-negotiable, learned the hard way):
- **Key auth is disabled** — every storage command uses `--auth-mode login`.
- **Signed links are user-delegation only** (`--as-user`) and **cannot exceed 7 days**.

---

## 7. Rebuild / teardown

```powershell
.\deploy.ps1 -Destroy     # asks you to TYPE the resource-group name; ~9 min
.\deploy.ps1 -Deploy      # ~15 min back to a working empty repo
```

`-Destroy` refuses to run against a list of protected groups (other projects' RGs).

**The repo remembers nothing.** Every package must be re-published after a rebuild
(`-Publish` per self-hosted file, `-GetManifest` + `-Ingest` per catalog app).
That is by design — the manifests *are* the approval record.

## 8. Known module bugs — scripted around, not fixed upstream

| # | Symptom | Cause | Our handling |
|---|---|---|---|
| 1 | Deploy dies: `Resource group '87c1d43f-…' could not be found` at the Cosmos role step | `New-ARMObjects.ps1` passes a principal GUID where a resource-group name belongs | `-Repair` assigns the role correctly |
| 2 | Function app answers **404** right after deploy | module aborts *before* publishing code (zero functions deployed) | `-Repair` publishes the module's stock zip and restarts |
| 3 | Entra (`AzureAD`) auth → 500 storm | upstream auth path broken for our config | we run `RestSourceAuthentication = 'None'` + function keys |
| 4 | `wingetcreate` crashes on `az storage blob generate-sas` URLs | tool builds temp filename from the query string (`&`, `=` illegal) — confirmed v1.12.13.0, unfiled upstream | `-Publish` builds manifests itself; wingetcreate not needed |

## 9. Troubleshooting

| What you see | Meaning | Do |
|---|---|---|
| `AuthorizationFailed`, roles "gone" | PIM activation expired | re-activate Owner, rerun |
| `KeyBasedAuthenticationNotPermitted` | key auth used | `--auth-mode login` |
| `incorrect usage: specify --as-user` | SAS without user-delegation | add `--as-user` |
| `--expiry should be within 7 days` | 7-day hard cap | expiry ≤ today+7 (script uses +6) |
| `cannot create container 'installers'` | no storage data role | grant Storage Blob Data Owner (§6) |
| Deploy stalls >25 min | ARM throttling / Cosmos slow | wait, then `-Repair` |
| 404 after rebuild | bug #2 or nothing published | `-Repair`, then republish |
| 503 bursts | host cold start / Azure incident | wait 1–2 min, `-Verify` again |

## 10. File map (ours, not Microsoft's `src/`)

| Path | What |
|---|---|
| `deploy.ps1` | the whole lifecycle: `-Deploy -Repair -Verify -Destroy -Publish -List -Fetch -Ingest -GetManifest -ClientTest` |
| `ui/ZB-Winget-UI.ps1`, `ui/Open-Panel.cmd` | click-driven control panel over the same switches |
| `scripts/verify-loop.ps1` | read-only health check, 6 checks |
| `deploy-settings.psd1(.example)` | your IDs (gitignored) / template |
| `USERS.md` | daily use: publish, list, fetch, install |
| `build-journal-*.md` | dated history; newest = current truth |
| `paw-build/` | next phase: PAW consumer VM (reference) |
