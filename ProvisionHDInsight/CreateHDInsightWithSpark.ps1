# 1. Ensure to install and Configure Windows Azure PowerShell from: 
# http://azure.microsoft.com/en-us/documentation/articles/install-configure-powershell/

# 2. Hive and Oozie sql dataabase needs to be created prior to excuting this script

$ClusterName = "**************"
$ClusterVersion = "3.2"                # 3.2 (HDP 2.2, Hadoop 2.6), 3.1(HDP 2.1, Hadoop 2.4)
$DataNodesNumber = 1                   # Number of data node, max is 22
$ClusterLocation = "China EAST"        # cluster location 
$HeadNodeVMSize = "Large"
$DataNodeVMSize = "Large"
$Endpoint = "https://management.core.chinacloudapi.cn/"    # Use https://management.core.windows.net/ for global Azure.
$ClusterUserName = "**************"
$ClusterPassword = "**************"
$SqlAzureServerName = "**************.database.chinacloudapi.cn"
$SqlAzureUserName = "**************"
$SqlAzurePassword = "**************"
$HiveSqlAzureDBName = "**************Hive"
$OozieSqlAzureDBName = "**************Oozie"

## Storage account and container info
$DefaultStorageAccountName = "**************"
$DefaultStorageAccountFqdn = "**************.blob.core.chinacloudapi.cn"
$DefaultContainerName = "hdidefault"
$HiveLibContainerName = "hdihivelibs"

$DefaultStorageAccountKey = Get-AzureStorageKey $DefaultStorageAccountName | %{ $_.Primary }

$ClusterPassword = ConvertTo-SecureString $ClusterPassword -AsPlainText -Force
$ClusterCreds = New-Object System.Management.Automation.PSCredential ($ClusterUserName, $ClusterPassword)
$SqlAzurePassword = ConvertTo-SecureString $SqlAzurePassword -AsPlainText -Force
$SqlAzureCreds = New-Object System.Management.Automation.PSCredential ($SqlAzureUserName, $SqlAzurePassword)

#
# Hadoop configuration files
#
# hdfs-site.xml configuration
$HdfsConfigValues = @{ "dfs.blocksize"="64m" }

# core-site.xml configuration
$CoreConfigValues = @{ "ipc.client.connect.max.retries"="60" } #default 50

# NOTE on capacity-scheduler.xml:
# Remember that, Capacity-scheduler is part of Yarn in HDInsight 3.x
# Accordingly, in HDInsight PowerShell, capacity-scheduler.xml configurations can be set via -Yarn parameter, which is a HashTable (for HDI 3.x clusters) 

# mapred-site.xml configuration
$MapRedConfigValues = New-Object 'Microsoft.WindowsAzure.Management.HDInsight.Cmdlet.DataObjects.AzureHDInsightMapReduceConfiguration'
$MapRedConfigValues.Configuration = @{ "mapreduce.task.timeout"="1200000" } #default 600000

# oozie-site.xml configuration
$OozieConfigValues = New-Object 'Microsoft.WindowsAzure.Management.HDInsight.Cmdlet.DataObjects.AzureHDInsightOozieConfiguration'
$OozieConfigValues.Configuration = @{ "oozie.service.coord.normal.default.timeout"="150" }  # default 120

# hive-site.xml configuration 
$HiveConfigValues = New-Object 'Microsoft.WindowsAzure.Management.HDInsight.Cmdlet.DataObjects.AzureHDInsightHiveConfiguration'
$HiveConfigValues.Configuration = @{ "hive.metastore.client.socket.timeout"="90";"mapred.input.dir.recursive"="true";"hive.mapred.supports.subdirectories"="true" }

# Hive Additional libraries, we can do the same for Oozie Additional Libraries
$HiveConfigValues.AdditionalLibraries = New-Object 'Microsoft.WindowsAzure.Management.HDInsight.Cmdlet.DataObjects.AzureHDInsightDefaultStorageAccount'
$HiveConfigValues.AdditionalLibraries.StorageAccountName = $DefaultStorageAccountFqdn  
$HiveConfigValues.AdditionalLibraries.StorageAccountKey = $DefaultStorageAccountKey 
$HiveConfigValues.AdditionalLibraries.StorageContainerName = $DefaultContainerName 

# In HDI 3.x, both yarn-site.xml and capacity-scheduler.xml configurations can be changed via -Yarn HashTable parameter
# In the example below, configuration element 'yarn.nodemanager.resource.memory-mb' belongs to yarn-site.xml and 
# 'yarn.scheduler.capacity.root.joblauncher.maximum-capacity' belongs to capacity-scheduler.xml
$YarnConfigValues = @{"yarn.nodemanager.resource.memory-mb"="6200";"yarn.scheduler.capacity.root.joblauncher.maximum-capacity"="60";}

# Create cluster 
New-AzureHDInsightClusterConfig -ClusterType Hadoop -ClusterSizeInNodes $DataNodesNumber -HeadNodeVMSize $HeadNodeVMSize -DataNodeVMSize $DataNodeVMSize |
    Set-AzureHDInsightDefaultStorage -StorageAccountName $DefaultStorageAccountFqdn -StorageAccountKey $DefaultStorageAccountKey -StorageContainerName $DefaultContainerName |
    Add-AzureHDInsightMetastore -SqlAzureServerName $SqlAzureServerName -DatabaseName $HiveSqlAzureDBName -Credential $SqlAzureCreds -MetastoreType HiveMetastore |
    Add-AzureHDInsightMetastore -SqlAzureServerName $SqlAzureServerName -DatabaseName $OozieSqlAzureDBName -Credential $SqlAzureCreds -MetastoreType OozieMetastore |
    Add-AzureHDInsightScriptAction -Name "Install Spark" -ClusterRoleCollection HeadNode -Uri https://hdiconfigactions.blob.core.windows.net/sparkconfigactionv03/spark-installer-v03.ps1 |
    Add-AzureHDInsightConfigValues -Hdfs $HdfsConfigValues -Core $CoreConfigValues -Hive $HiveConfigValues -MapReduce $MapRedConfigValues -Oozie $OozieConfigValues -Yarn $YarnConfigValues |
    New-AzureHDInsightCluster -Credential $ClusterCreds -Name $ClusterName -Location $ClusterLocation -Version $ClusterVersion -EndPoint $Endpoint
