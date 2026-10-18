/*
Shared hub details: the only place landing zones learn where the hub is.
Not deployed. Landing-zone param files import it:
  import { hub } from '../../platform/hub.bicep'
Set subscriptionId to the hub subscription, and keep resourceGroupName and vnetName in sync with platform/connectivity/main.bicep.
*/

var subscriptionId = '00000000-0000-0000-0000-000000000000'
var resourceGroupName = 'rg-hub-shared'
var vnetName = 'vnet-hub-shared-swedencentral-001'
// Router VM's static IP; must match routerIpAddress in platform/connectivity/main.bicep
var routerIpAddress = '10.0.0.4'

@export()
@description('Hub VNET location for landing zones')
var hub = {
  subscriptionId: subscriptionId
  resourceGroupName: resourceGroupName
  vnetName: vnetName
  vnetResourceId: '/subscriptions/${subscriptionId}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/virtualNetworks/${vnetName}'
  routerIpAddress: routerIpAddress
}
