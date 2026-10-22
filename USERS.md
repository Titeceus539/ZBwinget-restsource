# USERS — using the winget repo

Day-to-day: **publish** programs into our private store, **check** what's in it,
**download** files back out, **install** from it. No Azure knowledge needed.

Building or rebuilding the repo itself: see **BUILD.md**.

---

## The idea, in one picture

```
your PC ──publish──▶ our Azure repo ──install──▶ any Windows PC
```

A private app store: devs put programs in, machines install from it, and every install
is **hash-checked** — the file a machine receives must be byte-identical to what the
repo certified. Nothing comes from the public internet.

## Which command do I need?

| I want to… | Command |
|---|---|
| Publish a file I have | `.\deploy.ps1 -Publish -File <path> -PackageId <id> -Version <v> -Publisher <name>` |
| Publish a public-catalog app | `-GetManifest` ×2 then `-Ingest` (§4) |
| See what's in the repo | `.\deploy.ps1 -List` |
| Download a file back out | `.\deploy.ps1 -Fetch -PackageId <id> -Version <v>` |
| Install from the repo | `winget install --id <id> --source internal …` |
| Wire a new PC | `.\deploy.ps1 -ClientTest` (once per PC) |
| Is the repo healthy? | `.\deploy.ps1 -Verify` |

Prefer clicking? **`ui\Open-Panel.cmd`** (double-click) — every button runs the same commands.

---

## 1. The control panel (GUI)

**Open:** double-click `ui\Open-Panel.cmd` (or `pwsh -Sta -File .\ui\ZB-Winget-UI.ps1`).

| Area | Use it to |
|---|---|
| Header line | confirm which repo you're pointed at (`TmWinget2` · `tm-winget-rg`) |
| **Installer file + Browse…** | pick any `.exe` / `.msi` from disk — **the fields below fill themselves** from the file (public catalog ID used when the app is known) |
| Package ID / Version / Arch / Publisher / Description | metadata winget will show |
| **Publish to repo** | upload + hash + manifest + ingest in one go → `[PUBLISH_OK]` |
| **List packages in repo** | live table of everything in the store |
| **Check repo health** | `[HOST_UP]` means alive |
| **Setup winget on THIS PC** | one-time client wiring (UAC prompt → Yes) |
| **Install from repo** | runs `winget install` for the ID/version in the fields |
| **Open downloads folder** | where `-Fetch` saves files |
| Log pane | live output; status line shows green *done* or red *failed* |

Rule of thumb: the panel is a shell — anything it does, the CLI does identically.

## 2. One-time setup (per PC that installs from the repo)

```powershell
cd D:\code\ZBwinget-restsource\ZBwinget-restsource
az login
.\deploy.ps1 -ClientTest        # or the panel button
```
- UAC popup → **Yes** (registers the repo as a winget source; admin is required by winget itself).
- **Receipt:** a table listing a package.

## 3. Publish your own file (the common case)

**GUI:** Browse → fill fields → **Publish to repo**.

> Not sure what to type in each field? **`PUBLISHING.md`** shows how to read the right
> values straight off the file (with six worked examples from the demo kit).

**CLI — one line:**
```powershell
.\deploy.ps1 -Publish -File "C:\1-DEMO-Winget\ZB-DemoApp.exe" -PackageId Zenblox.DemoApp -Version 1.0.0 -Publisher Zenblox -Description "what it is"
```
**Receipt:** `[PUBLISH_OK]`.

What that one line does, in order:
1. uploads the file to the `installers` blob container;
2. computes the file's **SHA-256** on your machine;
3. creates a **user-delegation signed link** (7 days max — a hard Azure limit);
4. writes the three manifest files (version / installer / locale) in `manifests\<id>\<version>\`;
5. ingests them into the repo.

Notes:
- Re-running the same ID+version is **safe** — it overwrites and refreshes the link.
- Links die after **7 days**. If an install suddenly fails with a download error, re-publish.
- Package ID = `Publisher.Product`, e.g. `Zenblox.DemoApp`.

## 4. Publish a known public program (catalog path)

```powershell
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version list    # versions available
.\deploy.ps1 -GetManifest -PackageId 7zip.7zip -Version 26.04   # pull its manifests
.\deploy.ps1 -Ingest -ManifestDir .\manifests\7zip.7zip\26.04   # push into the repo
```
IDs come from github.com/microsoft/winget-pkgs and are **case-sensitive**
(folder `p/PuTTY/PuTTY` for ID `PuTTY.PuTTY`). Catalog manifests point at the vendor's
own download URL — no blob upload, no 7-day expiry.

## 5. Check what's in the store / get a file back out

```powershell
.\deploy.ps1 -List                                         # id · version · name · publisher · file
.\deploy.ps1 -Fetch -PackageId Zenblox.DemoApp -Version 1.0.0
.\deploy.ps1 -Fetch -PackageId Zenblox.DemoApp -Version 1.0.0 -OutDir "D:\temp"
```
- `-List` → **`[LIST_OK] n package(s)`**.
- `-Fetch` → **`[FETCH_OK]`** + the file's fingerprint, saved to `.\downloads`.
  A corrupted download is **deleted automatically** and the command fails — never kept.

## 6. Install from the repo

```powershell
winget search <name> --source internal
winget install --id Zenblox.DemoApp --version 1.0.0 --source internal --accept-package-agreements --accept-source-agreements
```

**The line that matters:**
```
Successfully verified installer hash
Successfully installed
```
The first line = the file arrived byte-identical to what the repo certified. If it
doesn't appear, the repo served something different and winget refused.

Uninstall / unwire:
```powershell
winget uninstall --id Zenblox.DemoApp
winget source remove internal          # admin terminal; forgets the repo on that PC only
```

## 7. Demo kit

`C:\1-DEMO-Winget\` holds verified demo files + `README.md` with ready lines:

| File | Story |
|---|---|
| `ZB-DemoApp.exe` | our own app — **exists nowhere on the internet** (best single beat) |
| `rufus-4.15.exe`, `tcpview64.exe`, `Bginfo64.exe` | portable third-party tools |
| `putty-64bit-installer.msi`, `7z2604-x64.exe` | classic installers (UAC) |
| `procexp64.exe` | already in the repo — "it's in the store" |

## 8. When something fails

| You see | Meaning | Fix |
|---|---|---|
| `AuthorizationFailed` / roles "vanished" | your PIM Owner expired | re-activate Owner in the portal, rerun |
| `cannot create container 'installers'` / blob permission error | no data role on the storage account | ask for **Storage Blob Data Owner** on it (BUILD.md §6) |
| `KeyBasedAuthenticationNotPermitted` | a storage command used key auth | `--auth-mode login` |
| Download/hash error during install | 7-day link expired | re-publish the package, retry |
| `winget` can't find the source | PC not wired, or stale catalog | `-ClientTest`, then `winget source update internal` |
| 404 from the API | repo rebuilt without re-publishing | re-publish; if persistent, see BUILD.md |
| `winget search` shows nothing | nothing published yet or wrong source | `-List` to confirm, `--source internal` |
| Publish hangs / fails at ingest | ARM throttling | wait 1 min, rerun the same line |

Ops-level (deploy / repair / destroy) → **BUILD.md**. History → `build-journal-*.md`.
