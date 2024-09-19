#requires -version 7

<#
    .SYNOPSIS
    Enable/Disable diagnostic settings for a list of storage accounts.

    .DESCRIPTION
    This script reads a CSV file with a list of storage accounts and enables or disables diagnostic settings for each of them.
    If the -EnableLogging switch is specified, the script will enable diagnostic settings for the storage accounts.
    If the -DisableLogging switch is specified, the script will disable diagnostic settings for the storage accounts.
    If neither -EnableLogging nor -DisableLogging are specified, the script will only check the current status of the diagnostic settings.

    .PARAMETER CSVFile
    The path to the CSV file with the list of storage accounts. The file must have a header with at least the following columns:
    - Id: the resource Id of the storage account
    - Name: the name of the storage account

    .PARAMETER WorkspaceId
    The Id of the log analytics workspace to use for diagnostic settings.

    .PARAMETER EnableLogging
    If specified, enables diagnostic settings for the storage accounts.

    .PARAMETER DisableLogging
    If specified, disables diagnostic settings for the storage accounts.

    .EXAMPLE
    .\set-laForStorageAccounts.ps1 -CSVFile .\storageAccounts.csv -WorkspaceId "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/myworkspace" -EnableLogging
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Specify the CSV file with the list of storage accounts")]
    [string]$CSVFile,
     
    [Parameter(Mandatory = $false, HelpMessage = "Specify the Id of the log analytics workspace to use")]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false, HelpMessage = "Specify if you want to enable diagnostic settings")]
    [switch]$EnableLogging,

    [Parameter(Mandatory = $false, HelpMessage = "Specify if you want to enable diagnostic settings")]
    [switch]$DisableLogging
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$diagSettingsName = "TempTLS10Analysis"

# if EnableLogging and DisableLogging are both specified, throw an error
if ($EnableLogging -and $DisableLogging) {
    throw "You cannot specify both -EnableLogging and -DisableLogging"
}

# if EnableLogging is specified but WorkspaceId is not, throw an error
if ($EnableLogging -and -not $WorkspaceId) {
    throw "You must specify the -WorkspaceId parameter when using -EnableLogging"
}

# read the last line of the file and try to understand if delimiter is ; or ,
$delimiter = ','
$csvContent = Get-Content -Path $CSVFile -Tail 1
if ($csvContent -match ';') {
    $delimiter = ';'
}

# verify that Az module is installed
if (-not (Get-Module -Name Az -ListAvailable)) {
    throw "You must install the Az module before running this script"
}

# verify that we have an active context
if (-not (Get-AzContext)) {
    throw "You must be logged in to Azure before running this script (use: Connect-AzAccount)"
}

# prepare log categories
$storageReadlogs = New-AzDiagnosticSettingLogSettingsObject -Enabled:$true -Category StorageRead
$storageWriteLogs = New-AzDiagnosticSettingLogSettingsObject -Enabled:$true -Category StorageWrite
$storageDeleteLogs = New-AzDiagnosticSettingLogSettingsObject -Enabled:$true -Category StorageDelete
$logCategories = @($storageReadlogs, $storageWriteLogs, $storageDeleteLogs)

# import the list of storage accounts
$storageAccounts = Import-Csv -Path $CSVFile -Delimiter $delimiter

# Iterate through each storage account and fetch diagnostic settings
Write-Host "Processing $($storageAccounts.Count) storage accounts..."
$storageAccounts | Foreach-Object -ThrottleLimit 10 -Parallel {

    $currentDiagnosticSettings = Get-AzDiagnosticSetting -ResourceId "$($_.Id)/blobServices/default" -WarningAction SilentlyContinue
    $ourSettingsAlreadyInUse = (($currentDiagnosticSettings | Where-Object Name -eq $using:diagSettingsName) -ne $null)

    if ($null -eq $currentDiagnosticSettings)
    {
        if ($using:EnableLogging)
        {
            $newDiagnosticSettings = New-AzDiagnosticSetting -ResourceId "$($_.Id)/blobServices/default" -WorkspaceId $using:WorkspaceId -Name $using:diagSettingsName -Log $using:logCategories
            Write-Host "$($_.name): Our diagnostic Settings have been enabled."
        }
        else
        {
            Write-Host "$($_.name): No diagnostic settings in use."
        }
    }
    else {
        if ($using:EnableLogging)
        {
            if ($ourSettingsAlreadyInUse)
            {
                Write-Host "$($_.name): Our diagnostic settings have been already enabled, nothing to do."
            }
            else {
                Write-Host "$($_.name): Some diagnostic settings are enabled but not using our configuration. Check manually."
            }
        }
        elseif ($using:DisableLogging)
        {
            if ($ourSettingsAlreadyInUse)
            {
                Remove-AzDiagnosticSetting -ResourceId "$($_.Id)/blobServices/default" -name $using:diagSettingsName
                Write-Host "$($_.name): Our diagnostic settings have been disabled."
            }
            else {
                Write-Host "$($_.name): Some diagnostic settings are enabled but not using our configuration. Check manually."
            }
        }
        else {
            if ($ourSettingsAlreadyInUse)
            {
                Write-Host "$($_.name): Our diagnostic settings are enabled"
            }
            else {
                Write-Host "$($_.name): Some diagnostic settings are enabled but not using our configuration. Check manually"
            }
        }
    }
}
