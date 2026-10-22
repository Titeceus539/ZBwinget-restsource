# Publish a package downloaded from the internet

This guide walks through downloading a package with `winget`, uploading it to this
Azure-backed winget REST source, and installing it from the private source on a new
Windows PC.

The example uses **Process Explorer 17.2**, a portable x64 application. The current
`deploy.ps1 -Publish` workflow creates a `portable` installer manifest, so use it for
portable installers. Do not use it unchanged for conventional setup `.exe` or `.msi`
installers; those need the correct installer type and package-specific switches.

For other package types and metadata guidance, see [PUBLISHING.md](./PUBLISHING.md).
For the full client workflow, see [USERS.md](./USERS.md).

## 1. Prepare the publishing PC

Open PowerShell 7.4 or later in the repository directory. The publishing PC needs
`winget`, Azure CLI, the Azure PowerShell modules used by the project, and the
repository's `deploy-settings.psd1`.

```powershell
Set-Location 'D:\code\ZBwinget-restsource\ZBwinget-restsource'
az login
winget --version
```

The account also needs permission to publish to the configured resources. In particular,
the project requires **Storage Blob Data Owner** on the storage account. `deploy.ps1`
will establish or check its Azure PowerShell context when needed.

## 2. Download the package

Use the public winget source to download the exact package version and architecture:

```powershell
$stage = 'C:\WingetStaging\ProcessExplorer'
New-Item -ItemType Directory -Path $stage -Force | Out-Null

winget download --id Microsoft.Sysinternals.ProcessExplorer `
    --version 17.2 `
    --architecture x64 `
    --source winget `
    --download-directory $stage `
    --accept-source-agreements
```

Review the downloaded files:

```powershell
Get-ChildItem $stage -Recurse -File |
    Select-Object FullName, Length
```

If the download is an archive, extract it and use the actual installer file. Set
`$installer` to that file's full path. For this example, it should point to
`procexp64.exe`. Check its Authenticode signature before publishing:

```powershell
$installer = 'C:\path\to\procexp64.exe'
Get-AuthenticodeSignature -FilePath $installer |
    Format-List Status, SignerCertificate
```

Confirm the file and metadata are the ones you intend to publish. Do not publish an
archive as though it were a directly runnable portable installer.

## 3. Upload and publish to the Azure source

Run the project publish command with the package's exact ID, version, publisher, and
architecture:

```powershell
.\deploy.ps1 -Publish `
    -File $installer `
    -PackageId Microsoft.Sysinternals.ProcessExplorer `
    -Version 17.2 `
    -Publisher 'Microsoft Corporation' `
    -Description 'Task manager with handle and DLL detail' `
    -Architecture x64
```

The script uploads the file to the configured Azure Storage `installers` container,
computes its SHA-256 hash, creates a read-only signed link, generates the package
manifests, and ingests them into the REST source. Wait for the **`[PUBLISH_OK]`**
receipt.

Signed links created by this workflow expire after approximately six days (within
Azure's seven-day user-delegation SAS limit). If an install later fails because the
link expired, publish the package again.

## 4. Register the source on the new Windows PC

Make sure the new PC has **App Installer / winget**. If an authorized operator has the
repository settings and Azure permissions on that PC, they can run:

```powershell
Set-Location 'D:\code\ZBwinget-restsource\ZBwinget-restsource'
az login
.\deploy.ps1 -ClientTest
```

Approve the UAC prompt if one appears. This script gets the Function App key from Azure,
registers the source under the name `internal`, and runs a search as a connectivity
check.

For a new PC that does not have the repository settings or Azure access, have an
authorized operator provide the REST source URL and Function App key through an
approved secure channel. Then register it in PowerShell:

```powershell
$sourceUrl = 'https://<function-app>.azurewebsites.net/api?code=<FUNCTION_HOST_KEY>'
winget source add --name internal --arg $sourceUrl --type Microsoft.Rest
winget source update internal
```

Treat the Function App key as a credential. Do not commit it, place a real key in a
shared script, or send it through an unapproved channel.

## 5. Find and install the package

Check that the private source contains the package, then install the requested version:

```powershell
winget search --id Microsoft.Sysinternals.ProcessExplorer --source internal

winget install --id Microsoft.Sysinternals.ProcessExplorer `
    --version 17.2 `
    --source internal `
    --accept-source-agreements `
    --accept-package-agreements
```

The successful install output should include **`Successfully verified installer hash`**
and **`Successfully installed`**. The hash verification confirms that the downloaded
file matches the SHA-256 recorded in the manifest.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `winget` cannot find the private source | Register it with `.\deploy.ps1 -ClientTest` or `winget source add`, then run `winget source update internal`. |
| Publish fails creating or uploading to the blob container | Confirm the Azure account has **Storage Blob Data Owner** on the configured storage account and is logged in with `az login`. |
| Install reports a download or URL failure | The signed link may have expired; re-run the publish command. |
| Install reports a hash mismatch | Do not bypass the check. Verify the selected file and publish it again so the blob and manifest hash match. |
| An ordinary setup `.exe` or `.msi` does not install correctly | The current `-Publish` helper emits a `portable` manifest. Use or create a manifest with the correct installer type and switches instead. |
