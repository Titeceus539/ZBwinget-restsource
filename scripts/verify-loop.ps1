# scripts/verify-loop.ps1 - canonical verification for the deploy.ps1 loop.
# Run anytime:  pwsh ./scripts/verify-loop.ps1
# Scope: repo-side, read-only (parse, GitHub catalog reads, live Azure probe).
#        NO deletes, NO deploys, NO installs. Safe to run any time.
$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path $PSScriptRoot -Parent
$pass = 0; $fail = 0
function Check($n, $ok, $d = '') {
  if ($ok) { $script:pass++; Write-Host "PASS  $n $(if($d){"- $d"})" }
  else     { $script:fail++; Write-Host "FAIL  $n - $d" -ForegroundColor Red }
}

# 1. deploy.ps1 parses
$e = $null; $t = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$repoRoot\deploy.ps1", [ref]$t, [ref]$e)
Check 'deploy.ps1 parses clean' ($e.Count -eq 0) (($e | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; ')

# 2. settings shape (stock zip, key auth)
try {
  $s = Import-PowerShellDataFile "$repoRoot\deploy-settings.psd1"
  Check 'settings: auth=None + stock zip' (($s.RestSourceAuthentication -eq 'None') -and [string]::IsNullOrWhiteSpace([string]$s.RestSourcePath))
} catch { Check 'settings import' $false $_.Exception.Message }

# 3. manifest fetcher, lowercase branch (live GitHub)
$out = (& pwsh -NoProfile -File "$repoRoot\deploy.ps1" -GetManifest -PackageId 7zip.7zip -Version list 2>&1) | Out-String
Check 'GetManifest lowercase branch (7zip.7zip)' ($LASTEXITCODE -eq 0 -and $out -match '\d+')

# 4. manifest fetcher, uppercase-ID branch (live GitHub; letter folder must be lowercase)
$out = (& pwsh -NoProfile -File "$repoRoot\deploy.ps1" -GetManifest -PackageId PuTTY.PuTTY -Version list 2>&1) | Out-String
Check 'GetManifest uppercase branch (PuTTY.PuTTY)' ($LASTEXITCODE -eq 0 -and $out -match '0\.82')

# 5. real byte fetch through the fixed URL path
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("hermes-verify-" + (Get-Date -Format 'HHmmss'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$hdr = @{ 'User-Agent' = 'ZBwinget-restsource-verify'; Accept = 'application/vnd.github.raw' }
$got = 0
foreach ($f in 'PuTTY.PuTTY.yaml', 'PuTTY.PuTTY.installer.yaml', 'PuTTY.PuTTY.locale.en-US.yaml') {
  try {
    Invoke-WebRequest -Uri "https://api.github.com/repos/microsoft/winget-pkgs/contents/manifests/p/PuTTY/PuTTY/0.82.0.0/$f" -Headers $hdr -OutFile (Join-Path $tmpDir $f) -ErrorAction Stop
    $got++
  } catch { }
}
$hasId = Select-String -Path (Join-Path $tmpDir 'PuTTY.PuTTY.yaml') -Pattern 'PackageIdentifier: PuTTY.PuTTY' -Quiet -ErrorAction SilentlyContinue
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
Check 'manifest bytes fetch (3 files, ID present)' ($got -eq 3 -and $hasId) "got=$got"

# 6. live repo healthy (probe: 401/200 = up)
$out = (& pwsh -NoProfile -File "$repoRoot\deploy.ps1" -Verify 2>&1) | Out-String
Check 'live repo answers (HOST_UP)' ($out -match 'HOST_UP') ($out.Trim() -split '\r?\n' | Select-Object -Last 1)

Write-Host '-----'
Write-Host ("VERIFY_LOOP: {0} passed, {1} failed  (read-only; no Azure writes, no installs)" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0