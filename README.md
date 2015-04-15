# AzureAutomationScripts
A set of scripts for my personal azure dev/ops work.

##Migrate-AzureVM
Migrate Azure IaaS VM from one subscripiton to another subscription

##Move-AzureVHD
Move Azure IaaS VM vhd files from one storage to another storage account

##ProvisionHDInsight:

Script Name|Description
---|---
CreateHDInsight.ps1|Create Azure HDInsight cluster with 1 storage, 1 hive db, 1 oozie db. Let's call this cluster configuration.
CreateHDInsightMutipleStorages.ps1|Standard configuration plus additional storage account, and can be modified to add 3nd, 4th storage accounts etc.
CreateHDInsightWithSpark.ps1|Standard plus additional ScriptAction install Spark.
CreateHDInsightWithVNet.ps1|Standard plus joining cluster to a virtual network.
