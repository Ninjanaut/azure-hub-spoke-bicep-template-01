/*
Connectivity platform: owns the connectivity subscription. Deploy once, before any landing zone.
  az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/params/shared.bicepparam
Creates its own resource groups; add further platform resource groups and modules here the same way.
Landing zones find the hub through platform/hub.bicep; keep it in sync with the names built here.
*/

targetScope = 'subscription'

@description('Location for all hub resources')
param location string = deployment().location

@description('Hub resource group. Must match resourceGroupName in platform/hub.bicep.')
param resourceGroupName string = 'rg-hub-shared'

@description('Instance number used in resource names (CAF <###> component)')
param instance string = '001'

@description('Hub VNET address space')
param addressPrefix string = '10.0.0.0/22'

@description('Subnet reserved for the Linux router that will route spoke-to-spoke traffic')
param routerSubnetPrefix string = cidrSubnet(addressPrefix, 24, 0)

@description('Static private IP of the router VM (first usable address of the router subnet). Must match routerIpAddress in platform/hub.bicep.')
param routerIpAddress string = cidrHost(routerSubnetPrefix, 3)

@description('Router VM size. B1s (1 vCPU, 1 GiB, BS family) is enough for packet forwarding and the BS family usually has default quota; deallocate the VM when not in use.')
param routerVmSize string = 'Standard_B1s'

@description('Admin user on the router VM')
param adminUsername string = 'azureuser'

@description('SSH public key for the router VM admin user (from $env:ADMIN_SSH_PUBLIC_KEY via the params file)')
@secure()
param adminSshPublicKey string

@description('Tags applied to all hub resources')
param tags object = {}

// CAF naming: <type>-<workload>-<environment>-<region>-<###>
// Fixed environment: the hub is shared platform infrastructure for prod and non-prod spokes
var environment = 'shared'
var vnetName = 'vnet-hub-${environment}-${location}-${instance}'
var routerVmName = 'vm-router-${environment}-${location}-${instance}'

// -------------------- HUB RESOURCE GROUP (AVM) --------------------
module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: 'rg-hub-${environment}'
  params: {
    name: resourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- HUB VNET (AVM) --------------------
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: 'vnet-hub-${environment}-${location}-${instance}'
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: vnetName
    location: location
    tags: union(tags, { environment: environment })
    addressPrefixes: [
      addressPrefix
    ]
    subnets: [
      {
        name: 'snet-router-${environment}-${location}-${instance}'
        addressPrefix: routerSubnetPrefix
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- ROUTER VM (AVM) --------------------
// Forwards spoke-to-spoke traffic. Spoke route tables send other spokes' prefixes here.
// Forwarding is enabled on the NIC (enableIPForwarding) and in the OS (cloud-init).
// No public IP; manage it with `az vm run-command invoke` or the serial console.
module router 'br/public:avm/res/compute/virtual-machine:0.22.3' = {
  name: routerVmName
  scope: resourceGroup(resourceGroupName)
  params: {
    name: routerVmName
    location: location
    tags: union(tags, { environment: environment })
    vmSize: routerVmSize
    availabilityZone: -1
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    osDisk: {
      diskSizeGB: 30
      caching: 'ReadWrite'
      deleteOption: 'Delete'
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
    }
    adminUsername: adminUsername
    disablePasswordAuthentication: true
    publicKeys: [
      {
        keyData: adminSshPublicKey
        path: '/home/${adminUsername}/.ssh/authorized_keys'
      }
    ]
    customData: loadTextContent('router-cloud-init.yaml')
    // Managed boot diagnostics, needed for the serial console
    bootDiagnostics: true
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        enableIPForwarding: true
        // AVM enables it by default; B1s doesn't support accelerated networking
        enableAcceleratedNetworking: false
        deleteOption: 'Delete'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: vnet.outputs.subnetResourceIds[0]
            privateIPAllocationMethod: 'Static'
            privateIPAddress: routerIpAddress
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

// Values needed by landing zones
output resourceGroupName string = rg.outputs.name
output vnetId string = vnet.outputs.resourceId
output vnetName string = vnet.outputs.name
output routerIpAddress string = routerIpAddress
output routerVmName string = router.outputs.name
