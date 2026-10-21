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