# How to Use the Zenblox Winget Repo — User Guide

Plain steps. Copy-paste each command. If a step prints the "success receipt" shown
under it, it worked.

---

## What this is

A private winget package repo running on our Azure servers.
Windows' normal `winget` tool can install programs **from it** instead of the public
internet. You publish programs *into* it from your PC.

```
your PC --publish--> Azure repo --install--> any Windows PC
```

---

## 1. One-time setup (per PC that wants to install from the repo)

```powershell
cd D:\code\ZBwinget-restsource\ZBwinget-restsource
az login
.\deploy.ps1 -ClientTest
```
- A UAC popup appears → click **Yes** (needed once, to register the repo as a winget source).
- **Receipt:** a table listing a package, e.g. `7-Zip  7zip.7zip  26.04`.

## 2. Publish a program into the repo (3 commands)

```powershell
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version list    # see available versions
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version 26.04   # pull its manifest
.\deploy.ps1 -Ingest -ManifestDir .\manifests\7zip.7zip\26.04   # push into the repo
```
- Replace `7zip.7zip` with any package ID from the public catalog
  (github.com/microsoft/winget-pkgs). The ID is **case-sensitive** — copy it exactly.
- Step 1 (`-Version list`) shows what versions exist; pick one, then run steps 2–3 with it.
- **Receipt (step 3):** `PackageIdentifier  <the-id>`.

## 3. Install a program from the repo

```powershell
winget search 7zip --source internal
winget install --id 7zip.7zip --source internal --accept-source-agreements --accept-package-agreements
```
- **Receipt:** winget prints `Successfully verified installer hash` during install.
  That line = the download arrived byte-identical to what the repo certified.

## 4. Is the repo alive?

```powershell
.\deploy.ps1 -Verify
```
- **Receipt:** `[HOST_UP]` = working. Anything else, tell us / see the runbook.

## 5. Stop a PC from using the repo (unwire)

```powershell
winget source remove internal
```
(admin terminal; just forgets the repo on that PC — the repo itself keeps running)

## 6. Full rebuild from zero (admin/emergency)

```powershell
.\deploy.ps1 -Destroy    # asks you to TYPE the resource-group name to confirm
.\deploy.ps1 -Deploy     # ~15 min. Then re-publish your packages (step 2 above).
```
The repo remembers nothing between rebuilds — package manifests must be re-ingested
after a rebuild. That is by design.

---

## If something fails

| What you saw | Do this |
|---|---|
| `-Deploy` ends with an error about a Cosmos role assignment | Run `.\deploy.ps1 -Repair` — the script finishes the job the module forgot. |
| `winget search` finds nothing | Re-publish the package (step 2), then retry. |
| Everything answers 404 from the function app | Someone rebuilt without publishing; run step 2 for each package you need. |

Details, background, and full troubleshooting: `RUNBOOK.md` in the same folder.
History: `build-journal-*.md` (newest file = newest history).