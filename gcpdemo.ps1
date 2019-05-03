### Add Citrix Powershell snapin
    asnp citrix*

### parameters
	$resourceLocationName = "gcp"
	$serviceAccountEmail = "<email id>"
	$serviceACcountPrivateKey = "<private key>"
    $connectionName = "scriptconnection1"
	$hostingUnitName = "scripthostingunit1"
	$catalogName = "scriptcatalog1"
	$gcpRegion = "us-east1"
	$vpc = "azad3-net"
	$subnet = "azad3-sub0"	
	$domainName = "<domain name>"
	$domainUserName = "<Name of domain>"
	$domainPassword = "<Domain Password>"	
	$numberOfVmsToCreate = 2
	$machineNamingScheme = "azadscript1-##"
	$masterVm = "server2012vda"
	$masterVmSnapshot = "server2012base"
	$updateVmSnapshot = "server2012update"
	$hostingProject = "Mohammed Azad"
    $projectPath = "$($connectionPath)\$($hostingProject).project"
    $rootPath = "$($projectPath)\$($gcpRegion).region"

### CreateHostingConfiguration	
	## get the zone/resource location
	$zone = Get-ConfigZone | Where-Object { $_.Name -match $resourceLocationName }
	
	## encode the private key
	$secureKey = ConvertTo-SecureString $serviceACcountPrivateKey -AsPlainText -Force
	
	## create the connection
	$connectionPath = "XDHyp:\Connections\$($connectionName)"
	$connection = New-Item -ConnectionType "Custom" -PluginId "GcpPluginFactory" -HypervisorAddress @("http://cloud.google.com") -Path $connectionPath -Persist -ZoneUid $zone.Uid.Guid -UserName $serviceAccountEmail -SecurePassword $secureKey -Scope @()
	
	## tell broker about the connection
	New-BrokerHypervisorConnection -HypHypervisorConnectionUid $connection.HypervisorConnectionUid
	
	## create the hosting unit	
	#$rootPath = "XDHyp:\Connections\$($connectionName)\$($gcpRegion).region\"
	$networkPath = "$($rootPath)\$($vpc).virtualprivatecloud\$($subnet).network"
	$hostingUnitPath = "XDHyp:\HostingUnits\$($hostingUnitName)"
	$hostingUnit = New-Item -Path $hostingUnitPath -HypervisorConnectionName $connectionName -NetworkPath $networkPath -RootPath $rootPath -StoragePath @() -PersonalvDiskStoragePath @()
	
### CreateCatalog	

	## create the broker catalog
	$catalog = New-BrokerCatalog -AllocationType "Random" -PersistUserChanges "Discard" -MinimumFunctionalLevel 'L7_9' -Name $catalogName -ProvisioningType 'MCS' -SessionSupport "MultiSession" -ZoneUid $zone.Uid
	
	## create the identity pool
	$identityPool = New-AcctIdentityPool -IdentityPoolName $catalog.Name -NamingScheme $machineNamingScheme -NamingSchemeType Numeric -Domain $domainName	
	Set-BrokerCatalogMetadata -CatalogId $catalog.Uid -Name "Citrix_DesktopStudio_IdentityPoolUid" -Value $identityPool.IdentityPoolUid.Guid
	
	## create the prov scheme
	$masterImagePath = "$($hostingUnitPath)\$($masterVm).vm\$($masterVmSnapshot).snapshot"
	$networkMappingPath = "$($hostingUnitPath)\$($vpc).virtualprivatecloud\$($subnet).network"
    $networkMappings = @{}
    $networkMappings.Add("0", $networkMappingPath)
	$newProvSchemeTaskId = New-ProvScheme -CleanOnBoot `
		-CustomProperties "" `
		-IdentityPoolName $identityPool.IdentityPoolName `
		-InitialBatchSizeHint $numberOfVmsToCreate `
		-HostingUnitName $hostingUnit.HostingUnitName `
		-MasterImageVM $masterImagePath `
		-NetworkMapping $networkMappings `
		-ProvisioningSchemeName $catalogName `
		-RunAsynchronously 

	# here you have to wait for the prov scheme to finish
	Get-ProvTask $newProvSchemeTaskId.Guid
	# when the Status field is "Finished" it's done
	
	$provScheme = Get-ProvScheme -ProvisioningSchemeName $catalogName		
	Set-BrokerCatalog -Name $catalogName -ProvisioningSchemeId $provScheme.ProvisioningSchemeUid.Guid

	$controllers = Get-ConfigEdgeServer | Where-Object ZoneName -eq $resourceLocationName
	Add-ProvSchemeControllerAddress -ProvisioningSchemeUID $provScheme.ProvisioningSchemeUid.Guid -ControllerAddress $controllers

	
### AddMachineToCatalog

	## encode the domain password
	$secureDomainPassword = ConvertTo-SecureString $domainPassword -AsPlainText -Force
	## add identity for the new machine
	$accounts = New-AcctADAccount -ADPassword $secureDomainPassword -ADUserName $domainUserName -Count $numberOfVmsToCreate -IdentityPoolUid $identityPool.IdentityPoolUid.Guid
	
	## create the VMs
	$newProvVmTaskId = New-ProvVM -ADAccountName $accounts.SuccessfulAccounts.ADAccountName -ProvisioningSchemeName $provScheme.ProvisioningSchemeName -RunAsynchronously 
	
	# again you must wait for the task to finish
	Get-ProvTask $newProvVmTaskId.Guid
	
	$provVMs = Get-ProvVM -ProvisioningSchemeName $provScheme.ProvisioningSchemeName
	
	## lock the VMs
	$vmsToLock = $provVMs | Where-Object {$_.lock -eq $false}
	Lock-ProvVM -ProvisioningSchemeName $provScheme.ProvisioningSchemeName -Tag "Brokered" -VMID $vmsToLock.VMId
	
	## tell broker about each machine
	# foreach $account in $accounts
	$accounts.SuccessfulAccounts.ForEach({
        $brokerMachine = New-BrokerMachine -CatalogUid $catalog.Uid -MachineName $_.ADAccountSID        
    })
	
#########################################################################
#    Remove\delete commands are not tested yet as those commands are W.I.P
#########################################################################
	
### DeleteMachineFromCatalog

	## delete the machine from broker
	# deleting one for example
	$machineToDelete = Get-BrokerMachine -CatalogUid $catalog.Uid | Select-Object -Last 1
	Remove-BrokerMachine -MachineName $machineToDelete.SID
	
	## delete machines
	$provVMToDelete = Get-ProvVM -ProvisioningSchemeName $catalogName | Where-Object {$machineToDelete.SID -match $_.ADAccountSid}	
	Unlock-ProvVM -ProvisioningSchemeName $provScheme.ProvisioningSchemeName -VMID $provVMToDelete.vmid
	$removeProvVMTask = Remove-ProvVM -ProvisioningSchemeName $provScheme.ProvisioningSchemeName -VMName $provVMToDelete.VMName -RunAsynchronously
	# wait for task to finish
	
	#remove the identity
	Remove-AcctADAccount  -ADAccountSid $provVMToDelete.ADAccountSid -ADPassword $secureDomainPassword $domainUserName -Force -IdentityPoolUid $identityPool.IdentityPoolUid.Guid -RemovalOption "Delete"
	
### PowerActions

	## turn all machines in a catalog off
	$brokerMachines = Get-BrokerMachine -CatalogUid $catalog.Uid
	New-BrokerHostingPowerAction $brokerMachines -Action "TurnOn"
	# or "TurnOff", etc

### Lifecycle

	## publish the new image/snapshot
	$updateImagePath = "$($hostingUnitPath)\$($masterVm).vm\$($updateVmSnapshot).snapshot"
	$publishProvImageTaskId = Publish-ProvMasterVMImage -MasterImageVM $updateImagePath -ProvisioningSchemeName $catalogName -RunAsynchronously 
	# wait for the publish task
	
	## reboot the machines so that they pick up the new image
	$brokerMachines = Get-BrokerMachine -CatalogUid $catalog.Uid | Where-Object {$_.ImageOutOfDate}
	New-BrokerHostingPowerAction $brokerMachines -Action "Restart"

### DeleteCatalog - delete machines from catalog first 

	## remove the identity pool
	Remove-AcctIdentityPool -IdentityPoolUid $identityPool.IdentityPoolUid.Guid
	
	## remove the prov scheme
	Remove-ProvScheme -ProvisioningSchemeName $provScheme.ProvisioningSchemeName
	
	## remove the broker catalog
	Remove-BrokerCatalog -Name $catalogName
	
### Delete Hosting Unit & connection

	Remove-Item -Path $hostingUnitPath
	Remove-Item -Path $connectionPath