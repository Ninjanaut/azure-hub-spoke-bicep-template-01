/*
Landing zone (spoke): resource group + route table + VNET, peered with the hub in both directions,
plus an optional connectivity test VM (deployTestVm). Owned by the platform team.
Deploy once per landing zone, after platform/connectivity.
  az deployment sub create -n spoke-app1-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app1/dev.bicepparam
The hub → spoke peering is created in the hub resource group (possibly another subscription),
so the deploying identity needs network write access there too.
*/

targetScope = 'subscription'

@description('Short spoke purpose used in resource names, e.g. "app1"')
param spokeName string

@description('Spoke environment (CAF environment component). "shared" is reserved for the hub.')
@allowed([
  'prod'
  'dev'
  'test'
  'qa'
  'stage'
])
param environment string

@description('Location for all spoke resources')
param location string = deployment().location

@description('Spoke resource group')
param resourceGroupName string = 'rg-spoke-${spokeName}-${environment}'

@description('Instance number used in resource names (CAF <###> component)')
param instance string = '001'

@description('Spoke VNET address space. Must not overlap with the hub or any other spoke.')
param addressPrefix string

@description('Workload subnet prefix')
param workloadSubnetPrefix string = cidrSubnet(addressPrefix, 24, 0)

@description('Resource ID of the hub VNET (from platform/hub.bicep)')
param hubVnetResourceId string

@description('Private IP of the hub router VM (from platform/hub.bicep)')
param routerIpAddress string

// One supernet route covers every other spoke: the spoke's own VNET route and the hub's
// peering route are more specific (longest prefix wins), so only other spokes go to the router.
@description('Supernet containing the hub and all spokes. Traffic to it is sent to the hub router.')
param spokesAddressSpace string = '10.0.0.0/16'

@description('Tags applied to all spoke resources')
param tags object = {}

@description('Deploy a small Linux VM in the workload subnet to test spoke-to-spoke routing')
param deployTestVm bool = false

@description('Test VM size. D2pls_v6 (2 vCPU, 4 GiB, Arm64, Dplsv6 family) supports accelerated networking and has default quota; older sizes such as B1s are not offered to the spoke subscriptions in Sweden Central.')
param testVmSize string = 'Standard_D2pls_v6'

@description('Ubuntu 24.04 image SKU; must match the CPU architecture of testVmSize ("server-arm64" for Arm64 sizes, "server" for x64)')
param testVmImageSku string = 'server-arm64'

@description('Admin user on the test VM')
param adminUsername string = 'azureuser'

@description('SSH public key for the test VM admin user. Required when deployTestVm is true.')
@secure()
param adminSshPublicKey string = ''

// CAF naming: <type>-<workload>-<environment>-<region>-<###>
var nameSuffix = '${spokeName}-${environment}-${location}-${instance}'
var vnetName = 'vnet-${nameSuffix}'
var testVmName = 'vm-conntest-${nameSuffix}'

// CAF has no peering format; mirrors the VPN connection one: peer-<local>-to-<remote>
var hubPart = replace(last(split(hubVnetResourceId, '/')), 'vnet-', '')
var spokePart = nameSuffix

// -------------------- SPOKE RESOURCE GROUP (AVM) --------------------
module rg 'br/public:avm/res/resources/resource-group:0.4.4' = {
  name: resourceGroupName
  params: {
    name: resourceGroupName
    location: location
    tags: union(tags, { environment: environment })
    enableTelemetry: false
  }
}

// -------------------- SPOKE ROUTE TABLE (AVM) --------------------
module routeTable 'br/public:avm/res/network/route-table:0.5.0' = {
  name: take('rt-${nameSuffix}', 64)
  // Scoped by name, so the dependency on the resource group has to be explicit
  scope: resourceGroup(resourceGroupName)
  dependsOn: [
    rg
  ]
  params: {
    name: 'rt-${nameSuffix}'
    location: location
    tags: union(tags, { environment: environment })
    routes: [
      {
        name: 'to-other-spokes'
        properties: {
          addressPrefix: spokesAddressSpace
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: routerIpAddress
        }
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- SPOKE VNET + PEERINGS (AVM) --------------------
// Deployment names are limited to 64 chars (peering names to 80)
module vnet 'br/public:avm/res/network/virtual-network:0.10.2' = {
  name: take('vnet-${nameSuffix}', 64)
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
        name: 'snet-${nameSuffix}'
        addressPrefix: workloadSubnetPrefix
        routeTableResourceId: routeTable.outputs.resourceId
      }
    ]
    peerings: [
      {
        // Spoke → hub, created on the spoke VNET
        name: 'peer-${spokePart}-to-${hubPart}'
        remoteVirtualNetworkResourceId: hubVnetResourceId
        allowVirtualNetworkAccess: true
        // Required for spoke-to-spoke traffic through the hub router
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: false
        // Hub → spoke, created on the hub VNET by a module scoped to the hub resource group
        remotePeeringEnabled: true
        remotePeeringName: 'peer-${hubPart}-to-${spokePart}'
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowGatewayTransit: false
        remotePeeringUseRemoteGateways: false
      }
    ]
    enableTelemetry: false
  }
}

// -------------------- CONNECTIVITY TEST VM (AVM, optional) --------------------
// Throwaway VM for testing spoke-to-spoke routing. Setting deployTestVm back to false doesn't remove it
// (incremental deployment); delete it with az vm delete (its NIC and disk go with it).
// No public IP; use `az vm run-command invoke`.
module testVm 'br/public:avm/res/compute/virtual-machine:0.22.3' = if (deployTestVm) {
  name: take(testVmName, 64)
  scope: resourceGroup(resourceGroupName)
  params: {
    name: testVmName
    location: location
    tags: union(tags, { environment: environment, purpose: 'connectivity-test' })
    vmSize: testVmSize
    availabilityZone: -1
    osType: 'Linux'
    imageReference: {
      publisher: 'Canonical'
      offer: 'ubuntu-24_04-lts'
      sku: testVmImageSku
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
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        enableAcceleratedNetworking: true
        deleteOption: 'Delete'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: vnet.outputs.subnetResourceIds[0]
          }
        ]
      }
    ]
    enableTelemetry: false
  }
}

output resourceGroupName string = rg.outputs.name
output vnetName string = vnet.outputs.name
output vnetId string = vnet.outputs.resourceId
output workloadSubnetId string = vnet.outputs.subnetResourceIds[0]
output testVmName string = deployTestVm ? testVmName : ''
output testVmPrivateIpAddress string = deployTestVm
  ? (testVm!.outputs.nicConfigurations[0].ipConfigurations[0].?privateIP ?? '')
  : ''
