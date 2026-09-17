Clear-Host
write-host "Starting script at $(Get-Date)"

Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
Install-Module -Name Az.Synapse -Force
Install-Module -Name SqlServer -Force -AllowClobber

# Handle cases where the user has multiple subscriptions
$subs = Get-AzSubscription | Select-Object
if($subs.GetType().IsArray -and $subs.length -gt 1){
        Write-Host "You have multiple Azure subscriptions - please select the one you want to use:"
        for($i = 0; $i -lt $subs.length; $i++)
        {
                Write-Host "[$($i)]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
        }
        $selectedIndex = -1
        $selectedValidIndex = 0
        while ($selectedValidIndex -ne 1)
        {
                $enteredValue = Read-Host("Enter 0 to $($subs.Length - 1)")
                if (-not ([string]::IsNullOrEmpty($enteredValue)))
                {
                    if ([int]$enteredValue -in (0..$($subs.Length - 1)))
                    {
                        $selectedIndex = [int]$enteredValue
                        $selectedValidIndex = 1
                    }
                    else
                    {
                        Write-Output "Please enter a valid subscription number."
                    }
                }
                else
                {
                    Write-Output "Please enter a valid subscription number."
                }
        }
        $selectedSub = $subs[$selectedIndex].Id
        Select-AzSubscription -SubscriptionId $selectedSub
        az account set --subscription $selectedSub
}

# Prompt user for a password for the SQL Database (also reused for the test VM's local admin account)
$sqlUser = "SQLUser"
write-host ""
$sqlPassword = ""
$complexPassword = 0

while ($complexPassword -ne 1)
{
    $SqlPassword = Read-Host "Enter a password to use for the $sqlUser login (this will also be used as the admin password for the test VM).
    `The password must meet complexity requirements:
    ` - Minimum 8 characters.
    ` - At least one upper case English letter [A-Z]
    ` - At least one lower case English letter [a-z]
    ` - At least one digit [0-9]
    ` - At least one special character (!,@,#,%,^,&,$)
    ` "

    if(($SqlPassword -cmatch '[a-z]') -and ($SqlPassword -cmatch '[A-Z]') -and ($SqlPassword -match '\d') -and ($SqlPassword.length -ge 8) -and ($SqlPassword -match '!|@|#|%|^|&|$'))
    {
        $complexPassword = 1
	    Write-Output "Password $SqlPassword accepted. Make sure you remember this!"
    }
    else
    {
        Write-Output "$SqlPassword does not meet the complexity requirements."
    }
}

# Register resource providers
Write-Host "Registering resource providers...";
$provider_list = "Microsoft.Synapse", "Microsoft.Purview", "Microsoft.Sql", "Microsoft.Storage", "Microsoft.Compute", "Microsoft.Network", "Microsoft.KeyVault", "Microsoft.DevTestLab"
foreach ($provider in $provider_list){
    $result = Register-AzResourceProvider -ProviderNamespace $provider
    $status = $result.RegistrationState
    Write-Host "$provider : $status"
}

# Generate unique random suffix
[string]$suffix =  -join ((48..57) + (97..122) | Get-Random -Count 7 | % {[char]$_})
Write-Host "Your randomly-generated suffix for Azure resources is $suffix"
$resourceGroupName = "dp000-$suffix"

# Region is fixed for every resource in this deployment.
# Central India ("centralindia") is blocked by this subscription's "Allowed resource deployment regions" policy.
# Of the regions that policy does allow (uaenorth, eastasia, indonesiacentral, indiasouthcentral, malaysiawest),
# uaenorth is the only one that supports both Microsoft.Synapse and Microsoft.Purview, so it's used here.
$Region = "uaenorth"
Write-Host "Using fixed region: $Region for all resources."

Write-Host "Creating $resourceGroupName resource group in $Region ..."
New-AzResourceGroup -Name $resourceGroupName -Location $Region | Out-Null

# Look up the signed-in user - used as the Azure AD admin on the Synapse workspace and for Key Vault access
Write-Host "Looking up signed-in user details..."
$currentUser = (az ad signed-in-user show) | ConvertFrom-Json
$userName = $currentUser.userPrincipalName
$aadAdminObjectId = $currentUser.id
$aadAdminTenantId = (Get-AzContext).Tenant.Id

# Detect the caller's public IP so RDP to the test VM can be locked down to it
Write-Host "Detecting your public IP address for the VM's network security group..."
$myIp = (Invoke-RestMethod -Uri "https://api.ipify.org?format=json").ip
Write-Host "RDP access to the test VM will be restricted to $myIp"

# VM admin credentials (username is fixed, password is reused from the SQL password above)
$vmAdminUsername = "azureadmin"
$vmAdminPasswordSecure = ConvertTo-SecureString $SqlPassword -AsPlainText -Force

# Create Synapse workspace, dedicated SQL pool, Purview account, Key Vault and test VM
$synapseWorkspace = "synapse$suffix"
$dataLakeAccountName = "datalake$suffix"
$sqlDatabaseName = "sql$suffix"
$purviewAccountName = "purview$suffix"
$keyVaultName = "kv$suffix"

write-host "Creating Azure resources in $resourceGroupName resource group..."
New-AzResourceGroupDeployment -ResourceGroupName $resourceGroupName `
  -TemplateFile "setup.json" `
  -Mode Complete `
  -workspaceName $synapseWorkspace `
  -dataLakeAccountName $dataLakeAccountName `
  -uniqueSuffix $suffix `
  -sqlDatabaseName $sqlDatabaseName `
  -sqlUser $sqlUser `
  -sqlPassword $sqlPassword `
  -purviewAccountName $purviewAccountName `
  -keyVaultName $keyVaultName `
  -aadAdminLogin $userName `
  -aadAdminObjectId $aadAdminObjectId `
  -aadAdminTenantId $aadAdminTenantId `
  -vmAdminUsername $vmAdminUsername `
  -vmAdminPassword $vmAdminPasswordSecure `
  -myIpAddress $myIp `
  -Force

# Make the current user and the Synapse service principal owners of the data lake blob store
write-host "Granting permissions on the $dataLakeAccountName storage account..."
write-host "(you can ignore any warnings!)"
$subscriptionId = (Get-AzContext).Subscription.Id
$id = (Get-AzADServicePrincipal -DisplayName $synapseWorkspace).id
New-AzRoleAssignment -Objectid $id -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;
New-AzRoleAssignment -SignInName $userName -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;

# Upload files
write-host "Loading data to data lake..."
$storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName
$storageContext = $storageAccount.Context
Get-ChildItem "./data/*.csv" -File | Foreach-Object {
    write-host ""
    $file = $_.Name
    Write-Host $file
    $blobPath = "products/$file"
    Set-AzStorageBlobContent -File $_.FullName -Container "files" -Blob $blobPath -Context $storageContext
}

# Create a service principal for dedicated SQL pool authentication (used by Purview to scan the pool)
write-host "Creating service principal for dedicated SQL pool authentication..."
$spName = "purview-synapse-sql-$suffix"
$spInfo = az ad sp create-for-rbac --name $spName | ConvertFrom-Json
$spAppId = $spInfo.appId
$spSecret = $spInfo.password

# Store the service principal's credentials in Key Vault so Purview can use them to connect to the dedicated SQL pool
write-host "Storing service principal credentials in $keyVaultName Key Vault..."
az keyvault secret set --vault-name $keyVaultName --name "synapse-sql-sp-appid" --value $spAppId | Out-Null
az keyvault secret set --vault-name $keyVaultName --name "synapse-sql-sp-secret" --value $spSecret | Out-Null

# Create database
write-host "Creating databases..."
$serverlessSQL = Get-Content -Path "serverless.sql" -Raw
$serverlessSQL = $serverlessSQL.Replace("datalakexxxxxxx", $dataLakeAccountName)
Set-Content -Path "serverless$suffix.sql" -Value $serverlessSQL
Invoke-Sqlcmd -ServerInstance "$synapseWorkspace-ondemand.sql.azuresynapse.net" -Username $sqlUser -Password $sqlPassword -Database "master" -InputFile "serverless$suffix.sql" -TrustServerCertificate

# Create the 3 tables in the dedicated SQL pool and grant the service principal read access
$dedicatedSQL = Get-Content -Path "dedicated.sql" -Raw
$dedicatedSQL = $dedicatedSQL.Replace("SQLSERVICEPRINCIPALNAME", $spName)
Set-Content -Path "dedicated$suffix.sql" -Value $dedicatedSQL
Invoke-Sqlcmd -ServerInstance "$synapseWorkspace.sql.azuresynapse.net" -Username $sqlUser -Password $sqlPassword -Database $sqlDatabaseName -InputFile "dedicated$suffix.sql" -TrustServerCertificate


# Pause SQL Pool
write-host "Pausing the $sqlDatabaseName SQL Pool..."
Suspend-AzSynapseSqlPool -WorkspaceName $synapseWorkspace -Name $sqlDatabaseName -AsJob

write-host ""
write-host "-----------------------------------------------------------------"
write-host "Deployment summary"
write-host "-----------------------------------------------------------------"
write-host "Resource group     : $resourceGroupName (Central India)"
write-host "Synapse workspace  : $synapseWorkspace"
write-host "Dedicated SQL pool : $sqlDatabaseName (3 tables: products, customers, orders)"
write-host "Purview account    : $purviewAccountName"
write-host "Key Vault          : $keyVaultName (holds the service principal's app id/secret)"
write-host "Test VM            : vm$suffix (Windows Server, RDP locked to $myIp)"
write-host ""
write-host "To finish connecting Purview to the dedicated SQL pool in Purview Studio:"
write-host "1. In Purview Studio > Management > Credentials, create a new credential of type 'Service Principal'"
write-host "   using app id/secret 'synapse-sql-sp-appid' / 'synapse-sql-sp-secret' from $keyVaultName (a Key Vault"
write-host "   connection to $keyVaultName may need to be added first under Management > Credentials > Manage Key Vault connections)."
write-host "2. Under Data Map > Register, register the Synapse workspace $synapseWorkspace (Purview's managed identity"
write-host "   already has Reader on it, so it should appear when browsing the subscription)."
write-host "3. Create a scan on the dedicated SQL pool $sqlDatabaseName, selecting the Service Principal credential"
write-host "   created in step 1. The service principal ($spName) already has db_datareader on the pool."
write-host "-----------------------------------------------------------------"

write-host "Script completed at $(Get-Date)"
