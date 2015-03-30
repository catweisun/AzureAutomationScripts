﻿<#
.Description
Migrate Azure IaaS VM from one subscripiton to another subscription

.Example
    .\Migrate-AzureVM.ps1 -SourceSubscriptionName "foo" -DestSubscritpionName "bar" -SourceCloudServiceName "foocs" -SourceVMName "foovm" -DestCloudServiceName "barcs" -DestStorageAccountName "barstorage" -DestLocationName "China East" -DestVNetName "foovnet"

#>

Param 
(
    [string] $SourceSubscriptionName,
    [string] $DestSubscritpionName,
    [string] $SourceCloudServiceName,
    [string] $SourceVMName,
    [string] $DestCloudServiceName,
    [string] $DestStorageAccountName,
    [string] $DestLocationName,
    [string] $DestVNetName
)

#Check the Azure PowerShell module version
Write-Host "Checking Azure PowerShell module verion" -ForegroundColor Green
$APSMajor =(Get-Module azure).version.Major
$APSMinor =(Get-Module azure).version.Minor
$APSBuild =(Get-Module azure).version.Build
$APSVersion =("$PSMajor.$PSMinor.$PSBuild")

If ($APSVersion -ge 0.8.14)
{
    Write-Host "Powershell version check success" -ForegroundColor Green
}
Else
{
    Write-Host "[ERROR] - Azure PowerShell module must be version 0.8.14 or higher. Exiting." -ForegroundColor Red
    Exit
}

Write-Host "`t================= Migration Setting =======================" -ForegroundColor Green
Write-Host "`t  Source Subscription Name = $SourceSubscriptionName       " -ForegroundColor Green
Write-Host "`t Source Cloud Service Name = $SourceCloudServiceName       " -ForegroundColor Green
Write-Host "`t            Source VM Name = $SourceVMName                 " -ForegroundColor Green
Write-Host "`t    Dest Subscription Name = $DestSubscritpionName         " -ForegroundColor Green
Write-Host "`t   Dest Cloud Service Name = $DestCloudServiceName         " -ForegroundColor Green
Write-Host "`t Dest Storage Account Name = $DestStorageAccountName       " -ForegroundColor Green
Write-Host "`t             Dest Location = $DestLocationName             " -ForegroundColor Green
Write-Host "`t                 Dest VNET = $DestVNetName                 " -ForegroundColor Green
Write-Host "`t===========================================================" -ForegroundColor Green

$ErrorActionPreference = "Stop"

try{ stop-transcript|out-null }
catch [System.InvalidOperationException] { }

$workingDir = (Get-Location).Path
$log = $workingDir + "\VM-" + $SourceCloudServiceName + "-" + $SourceVMName + ".log"
Start-Transcript -Path $log -Append -Force

Select-AzureSubscription -SubscriptionName $SourceSubscriptionName

#######################################################################
#  Check if the VM is shut down 
#  Stopping the VM is a required step so that the file system is consistent when you do the copy operation. 
#  Azure does not support live migration at this time.. 
#######################################################################
$sourceVM = Get-AzureVM –ServiceName $SourceCloudServiceName –Name $SourceVMName
if ( $sourceVM -eq $null )
{
    Write-Host "[ERROR] - The source VM doesn't exist. Exiting." -ForegroundColor Red
    Exit
}

# check if VM is shut down
if ( $sourceVM.Status -notmatch "Stopped" )
{
    Write-Host "[Warning] - Stopping the VM is a required step so that the file system is consistent when you do the copy operation. Azure does not support live migration at this time. If you’d like to create a VM from a generalized image, sys-prep the Virtual Machine before stopping it." -ForegroundColor Green
    $ContinueAnswer = Read-Host "`n`tDo you wish to stop $SourceVMName now? (Y/N)"
    If ($ContinueAnswer -ne "Y") { Write-Host "`n Exiting." -ForegroundColor Red; Exit }
    $sourceVM | Stop-AzureVM

    # wait until the VM is shut down
    $VMStatus = (Get-AzureVM –ServiceName $SourceCloudServiceName –Name $vmName).Status
    while ($VMStatus -notmatch "Stopped") 
    {
        Write-Host "Waiting VM $vmName to shut down, current status is $VMStatus" -ForegroundColor Green
        Sleep -Seconds 5
        $VMStatus = (Get-AzureVM –ServiceName $SourceCloudServiceName –Name $vmName).Status
    } 
}

# exporting the sourve vm to a configuration file, you can restore the original VM by importing this config file
# see more information for Import-AzureVM
$vmConfigurationPath = $workingDir + "\ExportedVMConfig-" + $SourceCloudServiceName + "-" + $SourceVMName +".xml"
Write-Host "Exporting VM configuration to $vmConfigurationPath" -ForegroundColor Green
$sourceVM | Export-AzureVM -Path $vmConfigurationPath

#######################################################################
#  Copy the vhds of the source vm 
#  You can choose to copy all disks including os and data disks by specifying the
#  parameter -DataDiskOnly to be $false. The default is to copy only data disk vhds
#  and the new VM will boot from the original os disk. 
#######################################################################

$sourceOSDisk = $sourceVM.VM.OSVirtualHardDisk
$sourceDataDisks = $sourceVM.VM.DataVirtualHardDisks

# Get source storage account information, not considering the data disks and os disks are in different accounts
$sourceStorageAccountName = $sourceOSDisk.MediaLink.Host -split "\." | select -First 1
$sourceStorageAccount = Get-AzureStorageAccount –StorageAccountName $sourceStorageAccountName
$sourceStorageKey = (Get-AzureStorageKey -StorageAccountName $sourceStorageAccountName).Primary 

Select-AzureSubscription -SubscriptionName $DestSubscritpionName
# Create destination context
$destStorageAccount = Get-AzureStorageAccount | ? {$_.StorageAccountName -eq $DestStorageAccountName} | select -first 1
if ($destStorageAccount -eq $null)
{
    New-AzureStorageAccount -StorageAccountName $DestStorageAccountName -Location $DestLocationName
    $destStorageAccount = Get-AzureStorageAccount -StorageAccountName $DestStorageAccountName
}
$DestStorageAccountName = $destStorageAccount.StorageAccountName
$destStorageKey = (Get-AzureStorageKey -StorageAccountName $DestStorageAccountName).Primary

$sourceContext = New-AzureStorageContext  –StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceStorageKey -Environment AzureChinaCloud
$destContext = New-AzureStorageContext  –StorageAccountName $DestStorageAccountName -StorageAccountKey $destStorageKey -Environment AzureChinaCloud

# Create a container of vhds if it doesn't exist
if ((Get-AzureStorageContainer -Context $destContext -Name vhds -ErrorAction SilentlyContinue) -eq $null)
{
    Write-Host "Creating a container vhds in the destination storage account." -ForegroundColor Green
    New-AzureStorageContainer -Context $destContext -Name vhds
}

$allDisks = @($sourceOSDisk) + $sourceDataDisks
$destDataDisks = @()
# Copy all data disk vhds
# Start all async copy requests in parallel.
foreach($disk in $allDisks)
{
    $blobName = $disk.MediaLink.Segments[2]
    # copy all data disks 
    Write-Host "Starting copying data disk $($disk.DiskName) at $(get-date)." -ForegroundColor Green
    $sourceBlob = "https://" + $disk.MediaLink.Host + "/vhds/"
    $targetBlob = $destStorageAccount.Endpoints[0] + "vhds/"
    Write-Host "Start copy vhd to destination storage account"  -ForegroundColor Green
    Write-Host .\Tools\AzCopy.exe /Source:$sourceBlob /Dest:$targetBlob /SourceKey:$sourceStorageKey /DestKey:$destStorageKey /Pattern:$blobName /SyncCopy -ForegroundColor Green
    .\Tools\AzCopy.exe /Source:$sourceBlob /Dest:$targetBlob /SourceKey:$sourceStorageKey /DestKey:$destStorageKey /Pattern:$blobName /SyncCopy
    if ($disk –eq $sourceOSDisk)
    {
        $destOSDisk = $targetBlob + $blobName
    }
    else
    {
        $destDataDisks += $targetBlob + $blobName
    }
}

Add-AzureDisk -OS $sourceOSDisk.OS -DiskName $sourceOSDisk.DiskName -MediaLocation $destOSDisk
# Attached the copied data disks to the new VM
foreach($currenDataDisk in $destDataDisks)
{
    $diskName = ($sourceDataDisks | ? {$currenDataDisk.EndsWith($_.MediaLink.Segments[2])}).DiskName
    Write-Host "Add VM Data Disk $diskName" -ForegroundColor Green
    Add-AzureDisk -DiskName $diskName -MediaLocation $currenDataDisk
}

Write-Host "Import VM from " $vmConfigurationPath -ForegroundColor Green
Set-AzureSubscription -SubscriptionName $DestSubscritpionName -CurrentStorageAccountName $DestStorageAccountName

# Import VM from previous exported configuration plus vnet info
if (( Get-AzureService | Where { $_.ServiceName -eq $DestCloudServiceName } ).Count -eq 0 )
{
    New-AzureService -ServiceName $DestCloudServiceName -Location $DestLocationName
}
Import-AzureVM -Path $vmConfigurationPath | New-AzureVM -ServiceName $DestCloudServiceName -VNetName $DestVNetName -WaitForBoot
