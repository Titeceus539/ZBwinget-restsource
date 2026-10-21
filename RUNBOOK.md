# RUNBOOK — Self-Hosted winget Repository (REST Source) Test Loop

Operators run this branch's `deploy.ps1` to turn an Azure subscription into a private
winget package repository, then prove the full round trip on the local PC:

```
acquisition PC ──publish─▶ Azure Function + Cosmos DB (the repo) ──install─▶ any client
                                        ▲                                        │
                                        └────────── hash-verified download ──────┘
```

- **Publish (up):** a working folder of manifest YAMLs is pushed into the repo.
- **Install (down):** the client asks the repo for a package, receives its manifest,
  downloads the installer from the URL the manifest names, and winget verifies the
  installer hash against the manifest before execution. That check is automatic.

No AI tooling is required at any point — every command in this document is
copy-pasteable into a plain PowerShell 7.4+ session.

---

## 1. Repository layout

| Path | Role |
|---|---|
| `deploy.ps1` | The one script. All operations are switches on it (see §4). |
| `deploy-settings.psd1` | Real configuration (tenant/subscription IDs). **Gitignored — never commit, never force-add.** |
| `deploy-settings.psd1.example` | Placeholder template; copy → rename → fill in. |
| `RUNBOOK.md` | This document. |
| `build-journal-YYYY-MM-DD.md` | Change log per session — every state change gets an entry (owner rule). Read newest-first for current status. |
| `Parameters/` | ARM parameter files generated during deploy. Artifacts, not source; regenerated on each deploy. |
| `manifests/` | Downloaded package manifests awaiting ingest. |
| `paw-build/` | Archived, proven scripts from the earlier Azure consumer-VM build. Reference only — superseded by this loop. |

`README.md` at repo root is **upstream Microsoft documentation** for
winget-cli-restsource and is not ours to rewrite.

## 2. Prerequisites

| Requirement | Why / notes |
|---|---|
| PowerShell 7.4+ (`pwsh`) | `deploy.ps1` opens with `#Requires -Version 7.4`. Windows PowerShell 5.1 will refuse. |
| Azure CLI (`az`) installed and logged in | `az login` before starting. Both the script and parts of the module use it. |
| `Az` PowerShell module | Auto-installed by `-Deploy` if missing (`-Scope CurrentUser`). |
| `Microsoft.WinGet.RestSource` module | Auto-installed by `-Deploy` if missing. This is Microsoft's official deployment module for the REST source. |
| Azure rights | **Owner** on the target subscription (the deploy creates RBAC role assignments). |
| For `-ClientTest` | winget client (ships with Win11) and elevation — the script raises UAC itself when the machine-scope source add needs it. |
| Git LFS | Only if cloning this repo fresh (`git lfs install && git lfs pull`). |

## 3. One-time configuration

```powershell
Copy-Item .\deploy-settings.psd1.example .\deploy-settings.psd1   # if starting fresh
pwsh .\deploy-settings.psd1                                       # no-op; confirms it parses
```

| Key | Meaning |
|---|---|
| `TenantId` / `SubscriptionId` | Where the repo is deployed. Both validated against the live Azure context at run time; mismatch = hard stop. |
| `Name` | Seeds every resource name (storage `st<Name>`, cosmos, function app, vault…). Must be globally unique across all of Azure — name collisions are the #1 deploy failure. If a deploy fails on a name, change `Name` and redeploy. Only one "Developer/Free-tier" Cosmos account is allowed per tenant. |
| `ResourceGroup` | The resource group everything is created in, and everything in it is deleted by `-Destroy`. **Choose an empty/dedicated group.** |
| `Region` | Azure region, e.g. `australiaeast`. |
| `RestSourceAuthentication` | Keep `'None'` → read endpoints use a function key inside the winget source URL (proven, simplest posture). `'MicrosoftEntraId'` creates an Entra app registration and has produced hard-to-debug Cosmos 500s; flip only deliberately. |
| `RestSourcePath` / `TemplateFolderPath` | Leave `$null` → the module deploys its own bundled function package and ARM templates. Set only to test custom payloads. |
| `ImplementationPerformance` | `'Developer'` = free-tier Cosmos / smallest resources. `'Basic'` / `'Enhanced'` cost more. |

## 4. The loop, in order

Run each switch explicitly, in a terminal opened in the repo root
(`cd D:\code\ZBwinget-restsource\ZBwinget-restsource`).

| # | Command | What it does | Terminal receipt on success |
|---|---|---|---|
| 1 | `.\deploy.ps1 -Destroy` | Deletes the entire `ResourceGroup` (function app, Cosmos, storage, vault, insights). Asks to type the group name to confirm. | `[DESTROYED] '<rg>' is gone.` |
| 2 | `.\deploy.ps1 -Deploy` | Deploys a fresh repo with the official module, then runs the post-deploy repair (managed identity + Cosmos RBAC — the module leaves this gap), then polls the endpoint until it answers. 10–40 min. | `[HOST_UP] … -> 200` then `[DEPLOY_DONE]` |
| 3 | `.\deploy.ps1 -Verify` | Read-only: discovers resources, probes health. Use any time. | `[HOST_UP]` |
| 4 | `.\deploy.ps1 -GetManifest -PackageId 7zip.7zip` | Downloads one package's manifest YAMLs from microsoft/winget-pkgs into `.\manifests\<id>\<version>\`. `-Version list` shows available versions first. | `[MANIFEST_OK] <path>` |
| 5 | `.\deploy.ps1 -Ingest -ManifestDir .\manifests\7zip.7zip\<version>` | Pushes those YAMLs into the repo. | `[INGEST_OK]` |
| 6 | `.\deploy.ps1 -ClientTest` | Adds the repo as winget source `internal` on this PC (auto-elevates via UAC when needed), then runs a receipt search. | `[CLIENT_TEST_OK]` |
| 7 | *(manual)* `winget install --id <Id> --source internal --accept-source-agreements --accept-package-agreements` | Actual install of the ingested package. Kept manual by design — installs are always an operator decision. | `Successfully verified installer hash` in winget's output |

A safe sanity check before anything destructive: `.\deploy.ps1 -Verify`.

## 5. Safety rails (read before the first run)

- **Protected resource groups are hardcoded and refused.** `rg-winget-manual`,
  `rg-wingettest`, `rg-pawtest`, `tim_paw_gallery_rg`, `paw2-hp-rg`, plus any name
  starting `paw2`/`pawtest`, can never be destroyed by this script even if the
  settings file points at them. Do not remove that guard.
- **`-Destroy` deletes everything in the resource group**, not just the repo's own
  resources. This is why `ResourceGroup` in settings must be dedicated.
- **No secrets are stored anywhere.** The function key is fetched at run time and
  exists only inside the winget source definition (and a TEMP file during an
  elevated source add, deleted immediately after).
- **`deploy-settings.psd1` is gitignored on purpose.** It carries real directory
  IDs. `deploy-settings.psd1.example` must always contain placeholders only.

## 6. Troubleshooting

| Symptom | Cause | Action |
|---|---|---|
| Deploy fails validating `Parameters\storageaccount.json` ("Parameters"/"$Schema" casing) | Known module bug in its generated parameter files | Delete the `Parameters\` folder, rerun `-Deploy` (they regenerate). If it persists, rewrite the generated files to lowercase `parameters`/`$schema`. |
| `/api/information` returns 500 after deploy | The module wires Cosmos with local auth disabled but no managed identity → function has neither key nor identity | `-Deploy` runs this repair automatically (identity + RBAC + `CosmosUseAadAuth` + restart). If a manual session is needed: see `build-journal-2026-10-21.md` / `paw-build\build-journal-2026-10-20.md`. |
| Probe shows 503 for a long time | Host genuinely not up (startup wave or storage poisoning) | Wait — 503 ≠ up; only sub-500 counts. If it never clears in `-Deploy`'s window, check `az functionapp log tail -g <rg> -n <app>` or the portal's *Log stream*. |
| Storage/global name collision on deploy | `Name` not unique enough | Change `Name` in settings, rerun the loop from step 1. |
| `winget source add` fails in a normal terminal | Machine-scope source changes need elevation | Approve the UAC prompt `-ClientTest` raises; it retries elevated automatically. |
| `winget search … --source internal` returns nothing | Ingest not run, or run against a different (deleted) repo | Re-run `-Ingest`, then `-Verify` to confirm the same repo is live. |
| Any `az` command yields `AuthorizationFailed` | Azure role lapsed | Re-run `az login`; confirm Owner assignment on the subscription. |

## 7. Where history lives

Status, decisions, and gotchas are recorded in `build-journal-*.md` (newest first)
and `paw-build\build-journal-2026-10-20.md`. The runbook above stays evergreen —
date-specific findings belong in the journals, not here.