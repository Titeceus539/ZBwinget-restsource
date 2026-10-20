#Requires -Version 7.4

$ErrorActionPreference = 'Stop'
$settings = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'deploy-settings.psd1')

foreach ($moduleName in @('Az', 'Microsoft.WinGet.RestSource')) {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Install-Module -Name $moduleName -Scope CurrentUser -AllowClobber
    }
}

Import-Module Az.Accounts
Import-Module Microsoft.WinGet.RestSource

Connect-AzAccount -Tenant $settings.TenantId -Subscription $settings.SubscriptionId | Out-Null
$context = Set-AzContext -Tenant $settings.TenantId -SubscriptionId $settings.SubscriptionId
if ($context.Tenant.Id -ne $settings.TenantId -or $context.Subscription.Id -ne $settings.SubscriptionId) {
    throw 'The Azure context does not match deploy-settings.psd1.'
}

$sourceSettings = $settings.Clone()
$sourceSettings.Remove('TenantId')
$sourceSettings.Remove('SubscriptionId')

foreach ($pathSetting in @('TemplateFolderPath', 'ParameterOutputPath', 'RestSourcePath')) {
    if ([string]::IsNullOrWhiteSpace($sourceSettings[$pathSetting])) {
        $sourceSettings.Remove($pathSetting)
    } else {
        $sourceSettings[$pathSetting] = [System.IO.Path]::GetFullPath($sourceSettings[$pathSetting], $PSScriptRoot)
    }
}

$result = New-WinGetSource @sourceSettings
if (-not $result) {
    throw 'WinGet REST source deployment failed.'
}