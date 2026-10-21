# How to Use the Zenblox Winget Repo — User Guide

Plain steps. Copy-paste each command. If a step prints the "success receipt" shown
under it, it worked. Prefer clicking? Use the control panel: `ui\ZB-Winget-UI.ps1`.

---

## What this is

A private winget package repo running on our Azure servers. Windows' normal `winget`
tool installs programs **from it** instead of the public internet. You publish
programs *into* it from your PC.

```
your PC --publish--> Azure repo --install--> any Windows PC
```

## Which command do I need?

| I want to… | Run |
|---|---|
| Publish my own file | `.\deploy.ps1 -Publish -File <path> -PackageId <id> -Version <v> -Publisher <name>` |
| Publish a public-catalog app | `.\deploy.ps1 -GetManifest …` then `-Ingest` (see §2) |
| See what's in the repo | `.\deploy.ps1 -List` |
| Download a file back out | `.\deploy.ps1 -Fetch -PackageId <id> -Version <v>` |
| Install from the repo | `winget install --id <id> --source internal` |
| Is the repo alive? | `.\deploy.ps1 -Verify` |

---

## 1. One-time setup (per PC that wants to install from the repo)

```powershell
cd D:\code\ZBwinget-restsource\ZBwinget-restsource
az login
.\deploy.ps1 -ClientTest
```
- A UAC popup appears → click **Yes** (needed once, to register the repo as a winget source).
- **Receipt:** a table listing a package, e.g. `7-Zip  7zip.7zip  26.04`.

## 2. Publish a program into the repo

**Your own file (not in Microsoft's catalog) — ONE line:**
```powershell
.\deploy.ps1 -Publish -File "C:\path\to\YourApp.exe" -PackageId Zenblox.MyApp -Version 1.0.0 -Publisher Zenblox -Description "what it is"
```
= `[PUBLISH_OK]`. That line uploads the file to our storage, signs a link, fingerprints
it, writes the manifest and pushes it into the repo. Re-running it for the same
version just refreshes (safe).

**A known public program — three lines:**
```powershell
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version list    # see available versions
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version 26.04   # pull its manifest
.\deploy.ps1 -Ingest -ManifestDir .\manifests\7zip.7zip\26.04   # push into the repo
```
Package IDs come from github.com/microsoft/winget-pkgs and are **case-sensitive**.

## 3. Check what's in the repo / get a file back out

```powershell
.\deploy.ps1 -List                                          # table of the whole repo
.\deploy.ps1 -Fetch -PackageId Zenblox.MyApp -Version 1.0.0 # download it back, hash-verified
```
`-List` → `[LIST_OK]`. `-Fetch` → `[FETCH_OK]` + the file's fingerprint; a corrupted
download is deleted automatically, never kept. Files land in `.\downloads`.

## 4. Install a program from the repo

```powershell
winget search <name> --source internal
winget install --id <id> --version <v> --source internal --accept-package-agreements --accept-source-agreements
```
- **Receipt:** `Successfully verified installer hash` = the download is byte-identical
  to what the repo certified, then `Successfully installed`.

## 5. Is the repo alive?

```powershell
.\deploy.ps1 -Verify
```
**Receipt:** `[HOST_UP]` = working.

## 6. Stop a PC from using the repo (unwire)

```powershell
winget source remove internal    # admin terminal; forgets the repo on that PC only
```

## 7. Full rebuild from zero — ADMIN / EMERGENCY ONLY

```powershell
.\deploy.ps1 -Destroy    # asks you to TYPE the resource-group name to confirm
.\deploy.ps1 -Deploy     # ~15 min. Then re-publish your packages (§2).
```
The repo remembers nothing between rebuilds — that is by design.

---

## If something fails

| What you saw | Do this |
|---|---|
| `KeyBasedAuthenticationNotPermitted` | A storage command used `--auth-mode key`; this account forbids keys. Use `--auth-mode login`. |
| `AuthorizationFailed` / roles "vanished" | Your Azure Owner is time-limited (PIM). Re-activate Owner in the portal, then rerun the same command. |
| `-Deploy` errors about a Cosmos role assignment | `.\deploy.ps1 -Repair` — finishes what the module forgets. |
| `winget search` finds nothing | Re-publish (§2), then `winget source update internal`. |
| 404 from the function app | Someone rebuilt without re-publishing; run §2 per package. |

Ops details and module-bug notes: `RUNBOOK.md`. History: `build-journal-*.md`.
GUI users: `ui\ZB-Winget-UI.ps1` wraps the same commands — no CLI needed.