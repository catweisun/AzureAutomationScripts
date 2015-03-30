<#
.Description
Move Azure IaaS VM vhd files from one storage to another storage account

.Example
    .\Move-AzureVHD.ps1 -CloudServiceName "blairmovevhd" -VMName "blairmovevhd" -DestStorageAccountName "blairstorage" -VNetName "RVNET-SH01"
#>

Param 
(
    [string] $CloudServiceName,                   # Cloud service name of VM
    [string] $VMName,                             # VM Name
    [string] $DestStorageAccountName,             # Target storage account name
    [string] $VNetName                            # Virtual network name of VM
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

Write-Host "`t============= Migration Setting ============== " -ForegroundColor Green
Write-Host "`t Source Cloud Service = $CloudServiceName      " -ForegroundColor Green
Write-Host "`t Virtual Machine Name = $VMName                " -ForegroundColor Green
Write-Host "`t Dest Storage Account = $DestStorageAccountName" -ForegroundColor Green
Write-Host "`t                 VNET = $VNetName              " -ForegroundColor Green
Write-Host "`t============================================== " -ForegroundColor Green

$ErrorActionPreference = "Stop"

try{ stop-transcript|out-null }
catch [System.InvalidOperationException] { }

$workingDir = (Get-Location).Path
$log = $workingDir + "\VM-" + $CloudServiceName + "-" + $VMName + ".log"
Start-Transcript -Path $log -Append -Force

$currentSubscription = Get-AzureSubscription -Current
$cloudEnv = $currentSubscription.Environment

#######################################################################
#  Check if the VM is shut down 
#  Stopping the VM is a required step so that the file system is consistent when you do the copy operation. 
#  Azure does not support live migration at this time.. 
#######################################################################
$sourceVM = Get-AzureVM –ServiceName $CloudServiceName –Name $VMName
if ( $sourceVM -eq $null )
{
    Write-Host "[ERROR] - VM $VMName doesn't exist. Exiting." -ForegroundColor Red
    Exit
}

# check if VM is shut down
if ( $sourceVM.Status -notmatch "Stopped" )
{
    Write-Host "[Warning] - Stopping the VM is a required step so that the file system is consistent when you do the copy operation. Azure does not support live migration at this time. If you’d like to create a VM from a generalized image, sys-prep the Virtual Machine before stopping it." -ForegroundColor Yellow
    $ContinueAnswer = Read-Host "`n`tDo you wish to stop $SourceVMName now? (Y/N)"
    If ($ContinueAnswer -ne "Y") { Write-Host "`n Exiting." -ForegroundColor Red; Exit }
    $sourceVM | Stop-AzureVM

    # wait until the VM is shut down
    $VMStatus = (Get-AzureVM –ServiceName $CloudServiceName –Name $vmName).Status
    while ($VMStatus -notmatch "Stopped") 
    {
        Write-Host "Waiting VM $vmName to shut down, current status is $VMStatus" -ForegroundColor Green
        Sleep -Seconds 5
        $VMStatus = (Get-AzureVM –ServiceName $CloudServiceName –Name $vmName).Status
    } 
}

# exporting the sourve vm to a configuration file, you can restore the original VM by importing this config file
# see more information for Import-AzureVM
$vmConfigurationPath = $workingDir + "\ExportedVMConfig-" + $CloudServiceName + "-" + $VMName + ".xml"
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
$sourceContext = New-AzureStorageContext –StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceStorageKey -Environment $cloudEnv

# Create destination context
$destStorageAccount = Get-AzureStorageAccount | ? {$_.StorageAccountName -eq $DestStorageAccountName} | select -first 1
$DestStorageAccountName = $destStorageAccount.StorageAccountName
if ($destStorageAccount -eq $null)
{
    if ($sourceStorageAccount.Location -ne $null ) 
    {
        New-AzureStorageAccount -StorageAccountName $DestStorageAccountName -Location $sourceStorageAccount.Location
    } else {
        New-AzureStorageAccount -StorageAccountName $DestStorageAccountName -AffinityGroup $sourceStorageAccount.AffinityGroup
    }
    $destStorageAccount = Get-AzureStorageAccount -StorageAccountName $DestStorageAccountName
}
$destStorageKey = (Get-AzureStorageKey -StorageAccountName $DestStorageAccountName).Primary
$destContext = New-AzureStorageContext –StorageAccountName $DestStorageAccountName -StorageAccountKey $destStorageKey -Environment $cloudEnv

# Create a container of vhds if it doesn't exist
if ((Get-AzureStorageContainer -Context $destContext -Name vhds -ErrorAction SilentlyContinue) -eq $null)
{
    Write-Host "Creating a container vhds in the destination storage account." -ForegroundColor Green
    New-AzureStorageContainer -Context $destContext -Name vhds
}

Write-Host "Remove VM $VMName" -ForegroundColor Green
Remove-AzureVM –ServiceName $CloudServiceName –Name $VMName

# Copy all vhd disk blobs, including both OS and data disks
$allDisks = @($sourceOSDisk) + $sourceDataDisks
$destDataDisks = @()

Write-Host "Waiting utill all vhd disk locks are released" -ForegroundColor Green
do
{
    Start-Sleep -Seconds 10
    $disksInUse = Get-AzureDisk | Where-Object { ($_.AttachedTo.RoleName -eq $VMName) -and ($_.AttachedTo.HostedServiceName -eq $CloudServiceName) }
    Write-Host "Disk in use: $disksInUse.Count" -ForegroundColor Green
} while (($disksInUse -ne $null) -or ($disksInUse.Count -gt 0))

foreach($disk in $allDisks)
{
    Write-Host "Remove VM Disk $disk.DiskName" -ForegroundColor Green
    Remove-AzureDisk -DiskName $disk.DiskName
}

# Copy all data disk vhds
foreach($disk in $allDisks)
{
    $elapsed = [System.Diagnostics.Stopwatch]::StartNew()
    $blobName = $disk.MediaLink.Segments[2]
    Write-Host "Starting copying disk $blobName at $(get-date)" -ForegroundColor Green
    Write-Host "Source = $sourceContext.BlobEndpoint" -ForegroundColor Green
    Write-Host "Dest = $destContext.BlobEndpoint" -ForegroundColor Green

    $targetBlob = Start-AzureStorageBlobCopy -SrcContainer vhds -SrcBlob $blobName -DestContainer vhds -DestBlob $blobName -Context $sourceContext -DestContext $destContext -Force
    do 
    {
        if ($copyState.TotalBytes -gt 0 )
        {
            $percent = ($copyState.BytesCopied / $copyState.TotalBytes) * 100
            Write-Host "$blobName copy completed $('{0:N2}' -f $percent)%" -ForegroundColor Green
        }
        Start-Sleep -Seconds 10
        $copyState = $targetBlob | Get-AzureStorageBlobCopyState
    } while ($copyState.Status -ne "Success")
    Write-Host "$blobName copy ended at $(get-date)" -ForegroundColor Green
    Write-Host "$blobName copy total elapsed time: $($elapsed.Elapsed.ToString())" -ForegroundColor Green
    if ($disk -eq $sourceOSDisk)
    {
        $destOSDisk = $targetBlob
    }
    else
    {
        $destDataDisks += $targetBlob
    }
}

# Create OS and data disks 
Write-Host "Add VM OS Disk " $destOSDisk.MediaLink -ForegroundColor Green
Add-AzureDisk -OS $sourceOSDisk.OS -DiskName $sourceOSDisk.DiskName -MediaLocation $destOSDisk.ICloudBlob.Uri

foreach($currenDataDisk in $destDataDisks)
{
    $diskName = ($sourceDataDisks | ? {$_.MediaLink.Segments[2] -eq $currenDataDisk.Name}).DiskName
    Write-Host "Add VM Data Disk $currenDataDisk.ICloudBlob.Uri" -ForegroundColor Green
    Add-AzureDisk -DiskName $diskName -MediaLocation $currenDataDisk.ICloudBlob.Uri
}

Write-Host "Import VM from " $vmConfigurationPath -ForegroundColor Green
Set-AzureSubscription -SubscriptionName $currentSubscription.SubscriptionName -CurrentStorageAccountName $DestStorageAccountName

# do
# {
#     Write-Host $sourceVM.IpAddress " Waiting till ip becomes available" -ForegroundColor Green
#     Sleep -Seconds 10
#     $ip = Test-AzureStaticVNetIP –VNetName $VNetName –IPAddress $sourceVM.IpAddress
# } while ( $ip.IsAvailable -ne $true )

# Import VM with previous exported configuration plus vnet info
# TODO: Use Set-AzureStaticVNetIP to make sure private ip is unchanged
Import-AzureVM -Path $vmConfigurationPath | New-AzureVM -ServiceName $CloudServiceName -VNetName $VNetName -WaitForBoot

Stop-Transcript -ErrorAction SilentlyContinue