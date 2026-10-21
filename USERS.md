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

## 2. Publish a program into the repo

**If it's your own file (not in Microsoft's catalog) — ONE line:**
```powershell
.\deploy.ps1 -Publish -File "C:\path\to\YourApp.exe" -PackageId Zenblox.MyApp -Version 1.0.0 -Publisher Zenblox -Description "what it is"
```
= `[PUBLISH_OK]`. That single line uploads the file to our storage, signs a link, fingerprints the file, writes the manifest, and pushes it into the repo.

**If it's a known public program — three lines:**
```powershell
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version list    # see available versions
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version 26.04   # pull its manifest
.\deploy.ps1 -Ingest -ManifestDir .\manifests\7zip.7zip\26.04   # push into the repo
```
Package IDs come from github.com/microsoft/winget-pkgs and are **case-sensitive**.

## 2b. Check what's in the repo / get a file back out

```powershell
.\deploy.ps1 -List                                                        # table of everything in the repo
.\deploy.ps1 -Fetch -PackageId Zenblox.MyApp -Version 1.0.0               # download it back, hash-verified
.\deploy.ps1 -Fetch -PackageId Zenblox.MyApp -Version 1.0.0 -OutDir "D:\temp"
```
`-List` = **receipt `[LIST_OK]`**. `-Fetch` = **`[FETCH_OK]`** with the file's fingerprint printed; a corrupted download is deleted automatically, never kept.

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

## Zero knowledge? — Publish YOUR OWN file, every click (start to finish)

For when the file is one only you have (not in Microsoft's public catalog).

### Phase A — open the tools

1. Start button → type `powershell` → Enter. (Dark window opens; you type commands.)
2. `cd D:\code\ZBwinget-restsource\ZBwinget-restsource`
3. `az login` → browser opens → sign in with your Zenme account → back to the window.
   (Login lasts hours; if you later see AuthorizationFailed, do this again.)

### Phase B — put your file on the servers (per file)

*(Public-catalog programs skip B-1/B-2: go straight to `.\deploy.ps1 -GetManifest
-PackageId <id> -Version <v>` then `-Ingest` — see section 2 above.)*

4. Create the private installers locker (once, ever; safe to re-run) — NOTE: always
   `--auth-mode login`; this storage account forbids key auth:
```powershell
az storage container create --account-name sttmwinget2 --name installers --public-access off --auth-mode login -o none
```
5. Upload your file (point `--file` at wherever it sits on your PC):
```powershell
az storage blob upload --account-name sttmwinget2 --container-name installers --name MyApp-1.0.0.exe --file "C:\path\to\MyApp-1.0.0.exe" --auth-mode login -o none
```
6. Get the signed link (works until the expiry date, then dies — on purpose). Copy the output line:
```powershell
az storage blob generate-sas --account-name sttmwinget2 --container-name installers --name MyApp-1.0.0.exe --permissions r --expiry 2027-10-21 --https-only --auth-mode login --full-uri -o tsv
```
7. One-time helper install: `winget install Microsoft.WingetCreate`
8. Let it describe your file (computes the hash for you, asks short questions; pick an ID like `Zenblox.MyApp`):
```powershell
wingetcreate new "<paste the signed link here>"
```
9. Give the repo those generated yamls:
```powershell
.\deploy.ps1 -Ingest -ManifestDir "<folder wingetcreate printed>"
```
   → `[INGEST_OK]` = in stock at the servers.

### Phase C — install from the servers (per PC)

10. One-time wiring on that PC: Phase A, then `.\deploy.ps1 -ClientTest`
    (UAC popup → Yes; receipt = a table listing a package).
11. Install:
```powershell
winget install --id Zenblox.MyApp --source internal
```
    → The golden line: **`Successfully verified installer hash`** — byte-identical
    to what you uploaded, proven. Then `Successfully installed`.

Nothing is deleted, nothing is redeployed. Repeat Phase B per file, Phase C per PC.

---

## If something fails

| What you saw | Do this |
|---|---|
| `KeyBasedAuthenticationNotPermitted` on a storage command | You used `--auth-mode key` — this account forbids keys. Change the command to `--auth-mode login` (all commands in this file already use it). |
| `-Deploy` ends with an error about a Cosmos role assignment | Run `.\deploy.ps1 -Repair` — the script finishes the job the module forgot. |
| `winget search` finds nothing | Re-publish the package (step 2), then retry. |
| Everything answers 404 from the function app | Someone rebuilt without publishing; run step 2 for each package you need. |

Details, background, and full troubleshooting: `RUNBOOK.md` in the same folder.
History: `build-journal-*.md` (newest file = newest history).