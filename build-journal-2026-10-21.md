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
- Repo now live: https://func-tmwinget2.azurewebsites.net/api (keys via az functionapp keys list).
- NOT verified yet: host-key existence check (default key assumed), ingest, client round-trip.
- Files: deploy.ps1 edits committed (repair extension). RUNBOOK.md added (4e96526).
- Ad-hoc verification (13 checks, temp script, deleted after run): 12/13 pass -> found real bug in -GetManifest list mode (URL got /list appended -> GitHub 404). Fixed = ghFolder built without version, apiBase appends version only for real pulls. Re-run: 13/13 PASS incl. live GitHub listing (7zip.7zip -> 26.04, 26.03) + protected-RG guard + arg-validation + usage.
- NOT verified live (needs owner approval + az login): -Destroy/-Deploy/-Ingest/-ClientTest Azure paths; the health probe; the cosmos-identity repair.
