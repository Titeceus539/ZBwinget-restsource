# ui/Get-PackageMetadata.ps1 — reads a file's own metadata and suggests publish-field values.
# Dot-source from the panel:  . "$PSScriptRoot\Get-PackageMetadata.ps1"
# Standalone test:            pwsh -File .\ui\Get-PackageMetadata.ps1 -FilePath "C:\1-DEMO-Winget\rufus-4.15.exe"

param([string]$FilePath, [switch]$UseCatalog)

function Get-PeArchitecture {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path); $br = New-Object IO.BinaryReader($fs)
        $fs.Seek(0x3C, 'Begin') | Out-Null; $pe = $br.ReadInt32()
        $fs.Seek($pe + 4, 'Begin') | Out-Null; $machine = $br.ReadUInt16()
        $fs.Close()
        switch ($machine) { 0x8664 { 'x64' } 0x14C { 'x86' } 0xAA64 { 'arm64' } default { 'x64' } }
    } catch { 'x64' }
}

function Get-MsiMetadata {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $wi = New-Object -ComObject WindowsInstaller.Installer
        $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
        $si = $db.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $db, @(0))
        [pscustomobject]@{
            Title   = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(2))
            Subject = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(3))
            Author  = [string]$si.GetType().InvokeMember('Property', 'GetProperty', $null, $si, @(4))
        }
    } catch { $null }
}

function ConvertTo-Token {
    # "Akeo Consulting" -> "AkeoConsulting" ; "7-Zip" -> "7Zip"
    param([string]$Text)
    if (-not $Text) { return '' }
    ($Text -replace '[^A-Za-z0-9]', ' ').Split(' ', [StringSplitOptions]::RemoveEmptyEntries) -join ''
}

function Resolve-CatalogId {
    # If the app exists in the public winget catalog, its ID is the one to use
    # (same product identity everywhere). Returns '' when no confident match.
    # NOTE: the winget table pads with runs of spaces only sometimes - short rows are
    # single-spaced - so the ID is found as "the token containing a dot", not by columns.
    param([string]$ProductName, [string]$Version)
    if (-not $ProductName) { return '' }
    $productToken = ConvertTo-Token $ProductName
    try {
        $rows = foreach ($line in (& winget search --name $ProductName --source winget --accept-source-agreements 2>$null)) {
            if ($line -notmatch '\S' -or $line -match '^-+\s*$' -or $line -match '^Name\s') { continue }
            $parts = @($line -split '\s+' | Where-Object { $_ })
            $idIdx = -1
            for ($i = 0; $i -lt $parts.Count; $i++) { if ($parts[$i] -match '\.' -and $parts[$i] -notmatch '^[\d.]+$') { $idIdx = $i; break } }
            if ($idIdx -lt 1) { continue }
            [pscustomobject]@{
                Name = ($parts[0..($idIdx - 1)] -join ' ')
                Id   = $parts[$idIdx]
            }
        }
        # 1. strongest signal: the ID's product part equals the product name we read
        $byProduct = @($rows | Where-Object { ($_.Id -split '\.')[-1] -ieq $productToken })
        if ($byProduct.Count -eq 1) { return $byProduct[0].Id }
        # 2. exact display-name match
        $exact = @($rows | Where-Object { $_.Name -eq $ProductName })
        if ($exact.Count -eq 1) { return $exact[0].Id }
        # 3. single name prefix match
        $starts = @($rows | Where-Object { $_.Name -like "$ProductName*" })
        if ($starts.Count -eq 1) { return $starts[0].Id }
    } catch { }
    return ''
}

function Get-PackageMetadata {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$UseCatalog
    )

    $f  = Get-Item -LiteralPath $Path
    $vi = $f.VersionInfo
    $isMsi = $f.Extension -ieq '.msi'

    if ($isMsi) {
        $msi     = Get-MsiMetadata -Path $f.FullName
        $product = if ($msi) { $msi.Title } else { '' }
        $company = if ($msi) { $msi.Author } else { '' }
        $desc    = if ($msi) { $msi.Subject } else { '' }
        if ($desc -match '(\d+(?:\.\d+){1,3})') { $version = $Matches[1] } else { $version = '' }
        if ($product -match 'Installation Database' -or -not $product) {
            $product = ($f.BaseName -replace '(?i)(-?x?64|-?x86|-?installer|-?setup|-?v?\d.*)$', '').Trim()
        }
        # "PuTTY release 0.85 installer" -> "PuTTY" is the product; keep desc as-is for the human
        if ($desc -match '(?i)^(.*?)\s+release\s+\d') { if (-not $product) { $product = $Matches[1] } }
        $arch = if ($f.Name -match '64') { 'x64' } elseif ($f.Name -match 'x86|32') { 'x86' } else { 'x64' }
    } else {
        $product = $vi.ProductName; $company = $vi.CompanyName
        $desc    = $vi.FileDescription
        $version = if ($vi.ProductVersion) { $vi.ProductVersion } else { $vi.FileVersion }
        $arch    = Get-PeArchitecture -Path $f.FullName
    }

    $product = if ($product) { $product.Trim() } else { '' }
    $company = if ($company) { $company.Trim() } else { '' }
    $desc    = if ($desc) { $desc.Trim() } else { '' }
    $version = if ($version) { ($version.Trim() -replace '[^0-9.]', '').Trim('.') } else { '' }
    if ($version -match '^0+(\.0+)*$') { $version = '' }          # 0.0.0.0 = no real version

    if ($company -match '(?i)sysinternals') {
        $publisher = 'Microsoft Corporation'; $vendor = 'Microsoft.Sysinternals'
    } else {
        $publisher = $company
        # first CamelCase word: "AkeoConsulting" -> "Akeo" ; "IgorPavlov" -> "Igor"
        # ([regex] not -match: -match is case-INsensitive and would eat the whole token)
        $token  = ConvertTo-Token $company
        $vendor = [regex]::Match($token, '^[A-Z][a-z0-9]*').Value
        if (-not $vendor) { $vendor = $token }
        if (-not $vendor) { $vendor = ConvertTo-Token $product }
    }

    $productToken = ConvertTo-Token $product
    $packageId = if ($vendor -and $productToken) { "$vendor.$productToken" } else { '' }

    $catalogId = ''
    if ($UseCatalog -and $product) {
        $catalogId = Resolve-CatalogId -ProductName $product -Version $version
        if ($catalogId) { $packageId = $catalogId }
    }

    if ($desc -eq $product) { $desc = '' }     # "Rufus"/"Rufus" is noise

    [pscustomobject]@{
        File        = $f.Name
        Arch        = $arch
        Version     = $version
        Publisher   = $publisher
        Description = $desc
        ProductName = $product
        PackageId   = $packageId
        CatalogId   = $catalogId
        Signature   = try { (Get-AuthenticodeSignature $f.FullName).Status } catch { 'Unknown' }
    }
}

if ($FilePath) { Get-PackageMetadata -Path $FilePath -UseCatalog:$UseCatalog | Format-List }
