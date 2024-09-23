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

    # define the function to update the diagnostic settings within the parallel block
     function Update-StorageAccount {
        param (
            [string]$Id,
            [string]$Name,
            [string]$ServiceName,
            [string]$DiagSettingsName,
            [string]$WorkspaceId,
            [bool]$EnableLogging,
            [bool]$DisableLogging,
            [array]$LogCategories
        )

        $currentBlobDiagnosticSettings = Get-AzDiagnosticSetting -ResourceId "$($Id)/$($ServiceName)" -WarningAction SilentlyContinue
        $ourSettingsAlreadyInUse = ($null -ne ($currentBlobDiagnosticSettings | Where-Object Name -eq $DiagSettingsName))

        if ($null -eq $currentBlobDiagnosticSettings) {
            if ($EnableLogging) {
                $newDiagnosticSettings = New-AzDiagnosticSetting -ResourceId "$Id/$ServiceName" -WorkspaceId $WorkspaceId -Name $DiagSettingsName -Log $LogCategories
                Write-Host "$($Name)/$($ServiceName): Enabled"
            }
            else {
                Write-Host "$($Name)/$($ServiceName): ---"
            }
        }
        else {
            if ($EnableLogging) {
                if ($ourSettingsAlreadyInUse) {
                    Write-Host "$($Name)/$($ServiceName): Already enabled"
                }
                else {
                    Write-Host "$($Name)/$($ServiceName): Skipped (other settings in use, check manually)"
                }
            }
            elseif ($DisableLogging) {
                if ($ourSettingsAlreadyInUse) {
                    Remove-AzDiagnosticSetting -ResourceId "$($Id)/$($ServiceName)" -Name $DiagSettingsName
                    Write-Host "$($Name)/$($ServiceName): Disabled"
                }
                else {
                    Write-Host "$($Name)/$($ServiceName): Skipped (other settings in use, check manually)"
                }
            }
            else {
                if ($ourSettingsAlreadyInUse) {
                    Write-Host "$($Name)/$($ServiceName): Already enabled"
                }
                else {
                    Write-Host "$($Name)/$($ServiceName): Other settings in use"
                }
            }
        }
    }

    # call the function to update the diagnostic settings for blob services
    Update-StorageAccount -Id $_.Id -Name $_.Name -ResourceId -ServiceName "blobServices/default" -DiagSettingsName $using:diagSettingsName -WorkspaceId $using:WorkspaceId -EnableLogging $using:EnableLogging -DisableLogging $using:DisableLogging -LogCategories $using:logCategories

    # call the function to update the diagnostic settings for table services
    Update-StorageAccount -Id $_.Id -Name $_.Name -ResourceId -ServiceName "tableServices/default" -DiagSettingsName $using:diagSettingsName -WorkspaceId $using:WorkspaceId -EnableLogging $using:EnableLogging -DisableLogging $using:DisableLogging -LogCategories $using:logCategories

    # call the function to update the diagnostic settings for table services
    Update-StorageAccount -Id $_.Id -Name $_.Name -ResourceId -ServiceName "queueServices/default" -DiagSettingsName $using:diagSettingsName -WorkspaceId $using:WorkspaceId -EnableLogging $using:EnableLogging -DisableLogging $using:DisableLogging -LogCategories $using:logCategories
}