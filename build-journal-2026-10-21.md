# BUILD JOURNAL — winget-restsource rebuild loop (root-level; supersedes paw-build journal)

## 2026-10-21 — step 1: deploy.ps1 rebuilt as full loop (no Azure touched)

OWNER DECISIONS:
- Scope corrected: paw-build (Azure PAW-consumer build) went too far too early. Real goal
  first = winget REST source build/test loop on the LOCAL PC (destroy -> deploy ->
  ingest -> client-test, all scripted, no-AI reproducible). PAW integration returns later.
- Function payload = **module's stock zip** (Option A). Old recovered payload
  (staging\payload-at-root.zip, hand-patched 10-15) stays staged, NOT served. Deploy
  must test what Microsoft's module builds.
- RestSourceAuthentication = **'None'** (function-key in source URL; proven posture —
  Entra path created the Cosmos-without-identity 500 storm 10-19).
- Name **TmWinget2** (sttmwinget name dead; module names resources st<Name>).

CHANGES (branch Tim, this journal + files committed):
- deploy.ps1 rewritten: -Destroy (RG delete w/ confirmation) / -Deploy (New-WinGetSource
  + post-deploy identity/RBAC repair + /api/information probe to 200) / -Verify (ro) /
  -GetManifest (pull version yamls from microsoft/winget-pkgs) / -Ingest
  (Add-WinGetManifest) / -ClientTest (winget source add auto-elevating + search receipt).
  Refuses protected RGs (rg-winget-manual, rg-wingettest, rg-pawtest, tim_paw_gallery_rg,
  paw2-hp-rg + paw2*/pawtest* prefix). No stored secrets.
- deploy-settings.psd1: auth None, RestSourcePath/template $null (stock zip), Name TmWinget2.
- deploy-settings.psd1.example: real tenant/sub IDs REPLACED with placeholders (leak fix).

KNOWN LIVE FINDINGS carried forward (from paw-build/build-journal-2026-10-20.md):
- Module deploys cosmos disableLocalAuth=true WITHOUT identity wiring -> function 500s
  unless repair runs (scripted inside -Deploy now).
- 503 != host-up. Probe treats <500 as up, >=500 as keep-waiting.
- winget source add machine-scope needs elevation -> -ClientTest auto-elevates via UAC.

NEXT: step 2 = -Destroy stale tm-winget-rg, -Deploy first live run (needs owner OK +
az login at keyboard). rg-winget-manual & rg-wingettest DIE LAST (standing rule).
paw-build\ stays in place as reference until loop proven; attic-move deferred.

## 2026-10-21 — step 2 EXECUTED: destroy + deploy + repair = REPO LIVE (owner OK'd)

- DESTROY: tm-winget-rg (failed 10-20 module attempt, 8 resources incl. sttmwinget
  collision) deleted via .\deploy.ps1 -Destroy, name-typed confirmation, ~9 min
  (cosmos drains last). Guard verified: rg-winget-manual/rg-wingettest/rg-pawtest/
  paw2-hp-rg/gallery RGs untouched.
- DEPLOY: New-WinGetSource TmWinget2/australiaeast/Developer built EVERYTHING:
  log-TmWinget2, appi-TmWinget2, kv-TmWinget2, appcs-TmWinget2, sttmwinget2,
  asp-TmWinget2 (serverfarm), cosmos-tmwinget2 (+ DB WinGet + container Manifests),
  func-TmWinget2 + module's own role wiring. No name collisions.
- NEW MODULE BUG FOUND (v1.10.1, New-ARMObjects.ps1 ~line 206): New-AzCosmosDBSqlRoleAssignment
  called with -ResourceGroupName $FunctionApp.IdentityPrincipalId -> "Resource group
  '<GUID>' could not be found" -> module ABORTS AFTER arm build, BEFORE:
  (a) Cosmos role assignment (b) host-key creation (c) Publish-AzWebApp code publish (d) restart.
  First live proof of this bug; journal-2026-10-20's hand-build hit the same class of gap.
- deploy.ps1 extended: -Repair switch + auto-catch in -Deploy (MODULE_THREW_AFTER_BUILD ->
  repair path). Set-RepoRepair now idempotent for: identity+Cosmos RBAC (az cli, correct
  RG-name form), cosmos app settings, AND empty-function-app detection -> publishes module's
  own stock zip (Data\WinGet.RestSource.Functions.zip 44.5MB) via Publish-AzWebApp + restart.
  Bugfix en route: az --query 'length(@)' gets garbled by az cmd wrapper from this host ->
  use --query '[].name' + count empty instead.
- REPAIR RUN 2026-10-21 ~14:45: identity/RBAC/settings/cosmos ok -> app detected empty ->
  stock zip published -> restart -> probe 503,503 (cold start)... -> **401 = HOST UP,
  endpoints registered, function-keyed (module stock posture)** -> [REPAIR_DONE].
## 2026-10-21 — steps 3+4 EXECUTED: FULL ROUND TRIP PROVEN (manifest -> ingest -> client)

- Second ad-hoc verify round (temp script, deleted after): 6/6 PASS — parse, usage lists
  -Repair, NEW fn-list query returns 28 functions on live app, idempotent -Repair
  ("RBAC already in place / code present / no re-publish -> HOST_UP"), guard rail still
  fires, -Verify on live repo HOST_UP. (2 detail-string typos in the verify script itself
  surfaced; the checks' substance re-ran separately — noted for honesty, no product impact.)
- STEP 3: -GetManifest 7zip.7zip -Version 26.04 -> 3 yamls into manifests\7zip.7zip\26.04.
  x64 InstallerSha256 D54BF805... == the 10-20 staging pin (cross-confirmation, gate intact).
- STEP 3: -Ingest -ManifestDir ... -> [INGEST_OK] (module reports PackageIdentifier 7zip.7zip).
- STEP 4: -ClientTest -> non-elevated add refused (expected, machine scope) -> script
  auto-elevated, UAC approved by owner -> source "internal" =
  https://func-tmwinget2.azurewebsites.net/api?code=<fetched at runtime> -> winget search:
  **7-Zip 7zip.7zip 26.04** [CLIENT_TEST_OK].
- BONUS receipt: winget list --id 7zip.7zip shows installed 26.04.0.0 correlated to source
  "internal" (down-leg manifest matching proven on an existing install too).
- FULL INSTALL still pending: 7-Zip already installed -> fresh-install receipt needs an
  uninstalled package, owner's pick (installs stay per-item approval on this PC).
- LOOP STATE: destroy/verify/repair/deploy/getmanifest/ingest/clienttest ALL live-proven
  2026-10-21. PAW consumer-VM wiring (paw-build) returns as a later phase.

## 2026-10-21 ~16:55 — FINAL RECEIPT: FULL-INSTALL ROUND TRIP PROVEN

- `winget install --id Notepad++.Notepad++ --source internal` (owner-approved): repo found
  8.9.3, downloaded the installer, **"Successfully verified installer hash"**, **"Successfully
  installed"**. Exit 0. `winget list` confirms Notepad++ 8.9.3 registered with source internal.
- Meaning: package traveled GitHub -> acquisition PC -> Azure repo -> back to PC, hash-checked
  end to end. The loop owner asked for ("delete all, rebuild by script, install a program via
  the servers") is COMPLETE and reproducible by scripts alone (deploy.ps1 + verify-loop.ps1).
- In-repo packages now: 7zip.7zip 26.04, PuTTY.PuTTY 0.82.0.0, Notepad++.Notepad++ 8.9.3,
  CaddyServer.Caddy 2.10.1 (retired id, harmless).
- Ad-hoc verification (13 checks, temp script, deleted after run): 12/13 pass -> found real bug in -GetManifest list mode (URL got /list appended -> GitHub 404). Fixed = ghFolder built without version, apiBase appends version only for real pulls. Re-run: 13/13 PASS incl. live GitHub listing (7zip.7zip -> 26.04, 26.03) + protected-RG guard + arg-validation + usage.
- (Superseded 10-21: the Azure-side paths listed as "not verified" below were ALL live-proven later this same session — see sections above. Kept here only as the pre-run checklist.)
- STEP 3 (cont.): lowercase-letter-folder bug FIXED (list 404 for PuTTY.PuTTY: letter folder is lowercase, pub/prod mirror ID case). Proven: PuTTY 0.82.0.0 ingested -> winget show [OK]; CaddyServer.Caddy 2.10.1 ingested (Caddy RETIRED per owner 10-21 - do not use/install); Notepad++.Notepad++ 8.9.3 ingested (1 transient ARM timeout on key put, retry OK). FRESH-INSTALL receipt = owner-approved install of Notepad++ from source internal (pending owner OK).
- USERS.md added: plain user step-by-step guide (setup/publish/install/verify/unwire/rebuild + fail notes). Full RUNBOOK simplification deferred by owner until loop done.
- Canonical verification script added: scripts/verify-loop.ps1 (read-only: parse, settings shape, both GetManifest case branches vs live GitHub, 3-file byte fetch, live HOST_UP probe). First run: 6/6 PASS. Replaces the buggy throwaway temp verifiers; anyone can run it, no AI needed.
- RUNBOOK.md REWRITTEN (owner task #1, after loop completion): cut 114 lines -> ~50, super-direct style. Commands block, the two rules (Destroy scope + rebuild forgets packages), module-bugs section, 4-row symptom table. USERS.md stays the user guide; no overlap.
- USERS.md: full zero-knowledge walkthrough added (Phase A/B/C, corrected --auth-mode login commands live-verified by agent first; key-auth storage error added to fail table). Owner hit the key-auth error live during walkthrough dry-run — fix = login mode, all storage cmds corrected.
- Step 6 SOLVED + PINNED (user request): working user-delegation SAS = --as-user + --auth-mode login + expiry WITHIN 7 DAYS (key auth forbidden on sttmwinget2; userSAS capped at now+7d — two Azure hard rules, both hit live today). Owner PIM expiry identified as recurring "lost roles" cause (yesterday + today both explained). Roles now: sub Owner (PIM) + Storage Blob Data Owner on sttmwinget2 (permanent, self-granted 16:29). procexp64.exe uploaded. Future upload/ingest script MUST carry the pinned SAS command verbatim.
- STEP 8/SAS crash fixed IN SCRIPT (owner decision: script must absorb this, user never hand-writes manifests): new -Publish switch = ONE-LINE self-hosted publish. Does: container ensure -> blob upload -> local-file sha256 -> pinned SAS (as-user+login, 6d expiry) -> manifest triplet (spec 1.12.0, License field added after server rejected its absence) -> Add-WinGetManifest ingest -> prints the install line. LIVE-PROVEN end-to-end with procexp64.exe ingested as Test.Fake 0.1 (findable via winget show, correct blob URL + correct hash CDD3BF8F). wingetcreate confirmed UNUSABLE for SAS URLs (crashes building filename from query string) - documented.
- TEST.CLEANUP: Test.Fake deleted from repo via DELETE /api/packages/<id>?code=<key> (204; Authorization: keys header = 401, ?code= = the one that works). Repo verified clean: only 7zip/PuTTY/Caddy/Notepad++ remain. wingetcreate uninstall not needed (it was the tool that failed, not installed junk).
- MANIFEST-DELETE route lives in PackageFunctions.cs PackageDeleteAsync (DELETE packages/{id}).
- -Publish polish: blob upload now passes --overwrite (first real run hit BlobAlreadyExists noise on a re-publish of the same exe; flow was unaffected, warning was cosmetic). Parse OK.
- OWNER PUBLISH SUCCESS 2026-10-21 20:26Z: Microsoft.Sysinternals.ProcessExplorer 17.2 published self-hosted from sttmwinget2 installers blob -> [PUBLISH_OK] + repo listing confirms. SAS until 2026-10-27.
- DEV-UX PASS (owner request: make it easier to upload/check/ingest/download for other developers). Fixed: (1) -Publish had sttmwinget2 HARDCODED -> now discovers storage account from the function app AzureWebJobsStorage__blobServiceUri setting (works for any dev settings file, survives rebuilds); (2) container-create failure was silently swallowed -> now fails loudly with the Storage Blob Data Owner hint; (3) module spray of "App settings have been redacted" warnings suppressed (scoped $WarningPreference around Add-WinGetManifest only); (4) upload --overwrite already added. NEW VERBS: -List (repo table: id/version/name/publisher/file) and -Fetch -PackageId -Version [-OutDir] (download published installer back out, SHA-256 verified, corrupted download deleted). Verified 13/13 ad-hoc live incl. dynamic discovery receipt, list rows, fetch hash+size, unknown-package error path, and a full publish refactor run (temp id deleted after, repo back to 5 real packages). USERS.md + RUNBOOK.md updated to the new surface.
- P0 DONE (owner-approved): USERS.md rewritten — obsolete Zero-knowledge section DELETED (it taught the pre-fix SAS command without --as-user/7d cap and wingetcreate-on-SAS, both guaranteed failures); added "Which command do I need?" table; receipts kept; fail table gains PIM-role row. README.md: START HERE block prepended (USERS/GUI/RUNBOOK/deploy.ps1 map + paw-build marked as next phase) above Microsoft upstream docs. deploy-settings.psd1.example: trimmed to 5 required + 2 publisher fields, legacy marked. Stale Parameters/ deleted. paw-build/ UNTOUCHED per owner (next phase; today = its prerequisite).
- TIER-1 GUI ADDED: tools/ZB-Winget-UI.ps1 (WinForms control panel, ~300 lines, thin shell over deploy.ps1 == no duplicate logic) + tools/Open-Panel.cmd double-click launcher. Buttons: Browse/publish file (file picker + ID/version/arch/publisher/desc), List, Verify, Setup this PC, Install, Open downloads; live log pane streams child-process output via temp-file + timer (no UI freeze); status line shows receipt or failure; auto-relaunch under -Sta. Self-test mode (-SelfTest) clicks List itself and exits 0/1.
- GUI VERIFIED LIVE: SELFTEST PASS — click -> deploy.ps1 -List -> Azure -> 5-package table in log pane, exit 0. Screenshot reviewed manually (renders correct, no overlap). computer_use capture returned 0x0 twice (driver issue, not app) -> used the self-test hook instead, better evidence.
- ui/ move: files landed in upstream Tools/ first (Windows case-insensitivity: tools == Tools); moved to ui/ + all doc refs updated; header comments fixed. Self-test re-run after each change: PASS. Commit ff57253.
- DOCS SPLIT (owner request: two files, build-from-scratch -> daily use). RUNBOOK.md renamed BUILD.md and rewritten: architecture + cost table, prereqs incl. PIM, settings (5 fields), -Deploy -> [DEPLOY_DONE], verify (401=healthy), first publish, client wiring, publishing role grant, destroy/rebuild truth (manifests do not survive), 4 known module bugs incl. wingetcreate SAS crash, troubleshooting, file map. USERS.md rewritten: GUI-first (panel button table), per-command map, own-file publish (5-step under-the-hood explanation), catalog path, List/Fetch, install + golden hash line, demo-kit table, 8-row failure table. README pointer updated; no stale RUNBOOK refs. Cross-checked: all 10 documented switches exist in deploy.ps1; all referenced files exist; receipt names verified against source ([DEPLOY_DONE] corrected from a guessed [DEPLOY_OK]).
- CLEANUP (owner-approved, Option 1 quarantine): moved 8 upstream items + 5 Microsoft meta files into upstream/ via git mv (src 378 files/7.5MB, Tools module source, pipelines, documentation, .config, .github, CONTRIBUTING/CODE_OF_CONDUCT/SECURITY/SUPPORT/CODEOWNERS, scripts/Release -> upstream/Release). NOTHING deleted; all recoverable. Kept: deploy.ps1, ui/, scripts/verify-loop.ps1, paw-build/ (untouched, next phase), BUILD.md, USERS.md, README.md, journal, deploy-settings(.example), manifests/ (re-ingest cache), LICENSE, editorconfig/gitattributes/gitignore.
- SAFETY PROOF: pre-move grep found only 2 refs (README doc link updated to /upstream/..., .gitignore patterns re-prefixed to upstream/); all 3 scripts parse OK; verify-loop 5/6 with the ONE failure = AuthorizationFailed (PIM Owner expired 22 Oct, not caused by move) while winget still serves ProcessExplorer 17.2 from the repo => Azure untouched, client path intact. Root now 13 entries.
