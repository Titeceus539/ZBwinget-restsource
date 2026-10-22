# PUBLISHING — what to type in each field (with real examples)

You picked a file. The panel asks for **Package ID, Version, Publisher, Description, Arch**.
Short answer: **the file already knows** — read it, don't guess. This page shows how,
then walks six real files from `C:\1-DEMO-Winget\`.

> **Good news: the control panel already does this for you.** Select a file (Browse…, or
> paste a path and tab away) and it fills every box from the file's own metadata — and
> when the app exists in the public winget catalog, it swaps in the **catalog ID**
> (so Rufus becomes `Rufus.Rufus`, not a guessed `Akeo.Rufus`). Treat the filled values
> as a **suggestion** and correct anything odd. Files with no metadata (our own
> `ZB-DemoApp.exe` is one) leave the boxes blank on purpose and say which fields you must type.
> The rules and snippets below are for when you want to know *why*, or work from the CLI.

---

## 1. Read the file (copy-paste, tested)

### For `.exe` files

```powershell
function Show-PackageInfo {
    param([Parameter(Mandatory)][string]$Path)
    $f  = Get-Item $Path
    $vi = $f.VersionInfo
    $fs = [IO.File]::OpenRead($Path); $br = New-Object IO.BinaryReader($fs)
    $fs.Seek(0x3C, 'Begin') | Out-Null; $o = $br.ReadInt32()
    $fs.Seek($o + 4, 'Begin') | Out-Null; $m = $br.ReadUInt16(); $fs.Close()
    $arch = switch ($m) { 0x8664 { 'x64' } 0x14C { 'x86' } 0xAA64 { 'arm64' } default { 'unknown' } }
    [pscustomobject]@{
        File        = $f.Name
        Arch        = $arch
        Version     = if ($vi.ProductVersion) { $vi.ProductVersion } else { $vi.FileVersion }
        Publisher   = $vi.CompanyName
        ProductName = $vi.ProductName
        Description = $vi.FileDescription
        Signature   = (Get-AuthenticodeSignature $Path).Status
    }
}

Show-PackageInfo -Path "C:\1-DEMO-Winget\rufus-4.15.exe"
```

Output for Rufus:

```
File        : rufus-4.15.exe
Arch        : x64
Version     : 4.15.2396
Publisher   : Akeo Consulting
ProductName : Rufus
Description : Rufus
Signature   : Valid
```

### For `.msi` files

MSIs don't fill `VersionInfo` — read their installer database instead:

```powershell
$msi = "C:\1-DEMO-Winget\putty-64bit-installer.msi"
$wi  = New-Object -ComObject WindowsInstaller.Installer
$db  = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($msi, 0))
$si  = $db.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $db, @(0))
"The version : " + $si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(3))
"Manufacturer: " + $si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(4))
```

Output:

```
The version : PuTTY release 0.85 installer   → version = 0.85
Manufacturer: Simon Tatham                  → publisher = Simon Tatham
```

No PowerShell? Windows also shows most of this: right-click the file → **Properties →
Details** (Product name, File version, Company).

---

## 2. The five fields — rules and where the value comes from

| Field | Where it comes from | Rules |
|---|---|---|
| **Package ID** | Vendor + product name; **use the public winget ID if the app has one** (search github.com/microsoft/winget-pkgs), otherwise build your own | `Vendor.Product`, letters/digits/dots only, **no spaces**, PascalCase, unique in our repo. Never invent `Microsoft.*` for a non-Microsoft file. Own apps: `Zenblox.<Thing>` |
| **Version** | The file's own version (`ProductVersion`, MSI `Subject`, or vendor page) | Only digits and dots. Must **increase** for a new build — winget uses it to decide what's newer. Re-publishing the same version replaces it |
| **Publisher** | `CompanyName`, MSI `Manufacturer`, or the vendor's site | The real company name — the corporate one, not a marketing string. `Sysinternals - www.sysinternals.com` → publish as `Microsoft Corporation` |
| **Description** | `FileDescription`, or one sentence you write | Plain words, what it does, ~100 chars. This is what the store shows |
| **Arch** | The `Arch` line from the snippet | Must match the actual binary: `x64` (most modern), `x86` (32-bit), `arm64` (rare). Wrong arch = installs but won't run |

**How to pick an ID when the app is in the public catalog:** use the catalog's exact ID
(`Rufus.Rufus`, `7zip.7zip`, `PuTTY.PuTTY`). Then a machine that later switches between
our store and the public one sees the *same product identity*, not a duplicate.

---

## 3. Worked examples — your demo kit, real values

| File | Package ID | Version | Publisher | Description | Arch |
|---|---|---|---|---|---|
| `ZB-DemoApp.exe` | `Zenblox.DemoApp` | `1.0.0` | `Zenblox` | `Demo app built locally` | `x64` |
| `rufus-4.15.exe` | `Rufus.Rufus` | `4.15.2396` | `Akeo Consulting` | `USB boot stick writer` | `x64` |
| `tcpview64.exe` | `Microsoft.Sysinternals.TCPView` | `4.19` | `Microsoft Corporation` | `Live TCP connection viewer` | `x64` |
| `procexp64.exe` | `Microsoft.Sysinternals.ProcessExplorer` | `17.2` | `Microsoft Corporation` | `Task manager with handle/DLL detail` | `x64` |
| `7z2604-x64.exe` | `7zip.7zip` | `26.04` | `Igor Pavlov` | `File archiver` | `x64` |
| `putty-64bit-installer.msi` | `PuTTY.PuTTY` | `0.85.0.0` | `Simon Tatham` | `SSH and Telnet client` | `x64` |

Why each choice:

- **`ZB-DemoApp`** — our own file, so vendor prefix `Zenblox`. The binary carries no
  version info, so we *choose* `1.0.0` and bump it on every new build.
- **`Rufus.Rufus`** — matches the public catalog ID, so it lines up with the real product;
  publisher is the company behind it (`Akeo Consulting`), not the product name.
- **`Microsoft.Sysinternals.*`** — Sysinternals is Microsoft-owned. The EXE's CompanyName
  string is marketing fluff; publish the owner: `Microsoft Corporation`.
- **`7zip.7zip`** — the catalog ID looks odd (lowercase product twice) but it's the real one;
  copying it beats inventing `IgorPavlov.SevenZip`.
- **`PuTTY.PuTTY` 0.85** — the MSI reports 0.85, which is *newer* than the 0.82 already in
  our repo, so this publish behaves like a version update. That's the correct winget story.

---

## 4. What else you do after clicking Publish

The publish uploads, hashes, signs a link, writes manifests and ingests — that's it for the
repo side. Then prove it, in this order:

```powershell
winget source update internal                                   # 1. refresh client view
winget search Zenblox.DemoApp --source internal                 # 2. it's listed
winget install --id Zenblox.DemoApp --version 1.0.0 --source internal --accept-package-agreements --accept-source-agreements
```

Step 3 must print **`Successfully verified installer hash`** → `Successfully installed`.
That's the receipt that the whole chain (blob → link → manifest → client) worked.

**Ongoing rules**

| Situation | What to do |
|---|---|
| Same file re-published | safe — replaces manifest and refreshes the 7-day link |
| New build of the same app | bump **Version**, publish again; old version stays installable |
| Install fails with a download error after ~a week | the signed link expired — re-publish the package |
| Publishing the same version but different bytes | allowed, but confusing — prefer a version bump |
| Need to see everything | `.\deploy.ps1 -List` |
| Want the file itself, not an install | `.\deploy.ps1 -Fetch -PackageId <id> -Version <v>` |

## 5. Mistakes that bite (all seen in real life)

| Mistake | Symptom | Fix |
|---|---|---|
| ID contains a space or differs in case | `winget search` finds nothing / wrong package | IDs are case-sensitive, no spaces |
| Version not increased on a rebuild | winget says "already installed" and skips yours | bump the version |
| Arch guessed as x64 for a 32-bit exe | installs, then "not a valid Win32 application" | run the snippet, use its `Arch` |
| File edited after publishing | install fails with hash mismatch | re-publish after any change |
| Borrowing `Microsoft.*` for your own binary | it looks like a Microsoft package that isn't | use `Zenblox.*` |
| Publishing an MSI with a made-up version | upgrades behave oddly | read the MSI's real version (§1) |

## 6. GUI ↔ CLI mapping

| Panel field | CLI switch |
|---|---|
| Installer file (Browse…) | `-File "C:\path\file.exe"` |
| Package ID | `-PackageId Vendor.Product` |
| Version | `-Version 1.0.0` |
| Arch dropdown | `-Architecture x64` |
| Publisher | `-Publisher "Company Name"` |
| Description | `-Description "what it does"` |
| **Publish to repo** | the whole `.\deploy.ps1 -Publish …` line |

Everything else (list, health, install) is unchanged — see `USERS.md`.
