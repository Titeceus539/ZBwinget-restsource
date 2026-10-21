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
- Ad-hoc verification (13 checks, temp script, deleted after run): 12/13 pass -> found real bug in -GetManifest list mode (URL got /list appended -> GitHub 404). Fixed = ghFolder built without version, apiBase appends version only for real pulls. Re-run: 13/13 PASS incl. live GitHub listing (7zip.7zip -> 26.04, 26.03) + protected-RG guard + arg-validation + usage.
- (Superseded 10-21: the Azure-side paths listed as "not verified" below were ALL live-proven later this same session — see sections above. Kept here only as the pre-run checklist.)
