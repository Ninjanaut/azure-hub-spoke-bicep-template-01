# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A minimal Azure hub-and-spoke network written in Bicep. It's meant as material for a blog article and as base infrastructure for later proofs of concept, so keep it simple. It intentionally has no VPN gateway, no DNS and no firewall. The only goal is routing between spokes.

The layout follows the enterprise platform / landing-zone split, scaled down to one repo. Resources come from Azure Verified Modules (AVM).

Spoke-to-spoke traffic goes through a small Linux router VM in the hub's `snet-router` (static IP `10.0.0.4`). VNet peering isn't transitive, so each spoke's workload subnet has a route table with one route, `10.0.0.0/16` → `VirtualAppliance` → `10.0.0.4`. Longest prefix wins: the spoke's own VNet and the hub keep their more specific system and peering routes, so only traffic to other spokes goes to the router. The router reaches every spoke directly through the hub's peering routes, so return traffic needs no extra routes. Every peering sets `allowForwardedTraffic: true`. The router forwards packets because IP forwarding is on at both levels: on the NIC (`enableIPForwarding`) and in the OS (`net.ipv4.ip_forward=1` from `platform/connectivity/router-cloud-init.yaml`).

## Layout

```
platform/
  connectivity/main.bicep             # hub resource group + hub VNet + router VM (subscription scope)
  connectivity/router-cloud-init.yaml # enables IP forwarding in the router OS
  connectivity/params/shared.bicepparam
  hub.bicep                           # exported hub details for landing zones (not deployed)
landing-zones/
  main.bicep                          # one spoke resource group + route table + VNet + both peering directions + optional test VM (subscription scope)
  <spokeName>/<environment>.bicepparam
```

## Commands

All commands run in PowerShell 7 (`pwsh`) with the Azure CLI. Building and linting need no login.

```powershell
# Install Azure CLI and Bicep. The -e flag is short for --exact. It tells winget to match the package query exactly.
winget install -e --id Microsoft.AzureCLI 
az bicep upgrade

# Linting is static analysis of your code. The linter reads your .bicep file without deploying anything and flags things that are valid syntax but are likely mistakes, bad practice, or security risks.       
az bicep lint --file landing-zones/main.bicep  

# Compiles a Bicep file into a standard ARM JSON file.
az bicep build --file landing-zones/main.bicep 
# Param files that deploy a VM need $env:ADMIN_SSH_PUBLIC_KEY set (see "SSH key" below)
az bicep build-params --file landing-zones/app1/dev.bicepparam
az bicep build-params --file platform/connectivity/params/shared.bicepparam
```

### Sign in

```powershell
az login --tenant '<tenant-id>'                         # opens a browser; add --use-device-code on a machine without one
az account list -o table                                # subscriptions you can see
az account set --subscription '<hub-subscription-id>'   # select before each step below
az account show -o table                                # check the active subscription
```

`az deployment sub create` targets the active subscription, so switch with `az account set` between the hub and spoke steps. The hub → spoke peering uses the hub subscription from `hubVnetResourceId` regardless of the active one.

### SSH key (router and test VMs)

A Linux VM needs a password or an SSH key, and these templates only accept a key. You create the key pair yourself, once, as a dedicated key used only for this PoC. Azure doesn't generate it.

```powershell
# Once: create the key pair (OpenSSH is built into Windows 11). Run it in PowerShell, not cmd, WSL or Git Bash,
# and answer both passphrase prompts (empty is fine) or no files are written.
ssh-keygen -t ed25519 -f "$HOME\.ssh\azure-hub-spoke-template-01" -C "azure-hub-spoke-template-01"
#   C:\Users\<you>\.ssh\azure-hub-spoke-template-01      private key: stays on your machine, never share or commit it
#   C:\Users\<you>\.ssh\azure-hub-spoke-template-01.pub  public key: the one that goes to Azure

# Before each deployment, in the same PowerShell window
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"
$env:ADMIN_SSH_PUBLIC_KEY                               # check: prints one line, ssh-ed25519 AAAA... azure-hub-spoke-template-01

# Optional: set it permanently for your user (applies to newly opened windows)
[Environment]::SetEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY', (Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"), 'User')
```

- The variable holds the key's **text**, not the path to the file. A variable set with `$env:` only lasts until you close that PowerShell window.
- The hub param file and every landing-zone param file with `deployTestVm = true` read the variable with `readEnvironmentVariable('ADMIN_SSH_PUBLIC_KEY')`. If it isn't set, `az deployment` and `az bicep build-params` fail with `BCP427` (VS Code shows the same error until it's restarted from a window where the variable is set). A landing zone without a test VM doesn't need it.
- Azure writes the key into `/home/azureuser/.ssh/authorized_keys` **inside the VM**. That's what `publicKeys.path` in the templates means: a Linux path, not a Windows one. No key file is stored in the repo.
- One key for all VMs is fine for this PoC. In production, use one key per person (never a shared team key), or Microsoft Entra ID login for VMs.
- You rarely log in with it. The VMs have no public IP, and `az vm run-command invoke` doesn't use SSH.

### Deploy

```powershell
$env:ADMIN_SSH_PUBLIC_KEY = Get-Content "$HOME\.ssh\azure-hub-spoke-template-01.pub"   # every new PowerShell window; see "SSH key" above
# 1) Hub, once (active subscription: hub); the template creates rg-hub-shared itself
az account set --subscription '<hub-subscription-id>'
az deployment sub create -n hub-shared -l swedencentral -f platform/connectivity/main.bicep -p platform/connectivity/params/shared.bicepparam
# 2) Landing zone, one at a time (active subscription: spoke); the template creates rg-spoke-<spokeName>-<environment>, the route table,
#    the spoke VNet, peering both ways and, with deployTestVm = true, the test VM
az account set --subscription '<spoke-subscription-id>'
az deployment sub create -n spoke-app1-dev -l swedencentral -f landing-zones/main.bicep -p landing-zones/app1/dev.bicepparam
# Dry run: `az deployment sub what-if` with the same arguments
```

### Test spoke-to-spoke routing

```powershell
# The test VMs come from the landing-zone deployments above (deployTestVm = true in the param file), in the spoke resource group.
# The testVmPrivateIpAddress output gives each VM's IP (the first VM in a subnet gets .4: app1 10.0.4.4, app2 10.0.8.4)

# Routes the platform programmed: expect 10.0.0.0/16 -> VirtualAppliance 10.0.0.4
az network nic show-effective-route-table -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001-nic-01 -o table
# Real traffic: tracepath should show 10.0.0.4 as the hop before 10.0.8.4
az vm run-command invoke -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --command-id RunShellScript --scripts "ping -c 4 10.0.8.4; tracepath -n 10.0.8.4"
# Proof on the router (hub subscription, second terminal while the ping runs)
az vm run-command invoke -g rg-hub-shared -n vm-router-shared-swedencentral-001 --command-id RunShellScript --scripts "timeout 20 tcpdump -ni eth0 icmp"
# Negative test: turn forwarding off and the ping fails; turn it back on with =1
az vm run-command invoke -g rg-hub-shared -n vm-router-shared-swedencentral-001 --command-id RunShellScript --scripts "sysctl -w net.ipv4.ip_forward=0"

# Cleanup and cost: delete the test VMs (NIC and disk are deleted with them) and deallocate the router when idle.
# Also set deployTestVm = false in the param files, or the next landing-zone deployment recreates them.
az vm delete -g rg-spoke-app1-dev -n vm-conntest-app1-dev-swedencentral-001 --yes
az vm delete -g rg-spoke-app2-dev -n vm-conntest-app2-dev-swedencentral-001 --yes
az vm deallocate -g rg-hub-shared -n vm-router-shared-swedencentral-001
```

### Required permissions (Azure RBAC)

| Step | Scope | Minimum built-in role |
|---|---|---|
| Hub | hub subscription (the template creates `rg-hub-shared`) | Contributor |
| Landing zone | spoke subscription (the template creates `rg-spoke-…`) | Contributor |
| Landing zone | `rg-hub-shared` (hub → spoke peering, `peer/action` on the hub VNet, nested deployment) | Network Contributor |

- Both templates need the subscription scope because they create resource groups.
- `what-if` needs the same roles as the deployment it previews.
- The `Microsoft.Network` resource provider must be registered in each subscription. Contributor at subscription scope registers it automatically on first deployment; otherwise run `az provider register -n Microsoft.Network`.
- Hub and spoke subscriptions must be in the same Microsoft Entra tenant for a single-identity deployment; cross-tenant peering isn't supported by these templates.

## Architecture

- **Two templates, both subscription-scoped.** The platform team owns the connectivity subscription and the landing-zone networking. `platform/connectivity/main.bicep` creates `rg-hub-shared` and the hub VNet in it, and future platform resource groups and resources go there too. `landing-zones/main.bicep` creates one spoke resource group, the route table and the spoke VNet in it, and peers it with the hub. With `deployTestVm = true` it also adds a throwaway test VM (`vm-conntest-…`) to the workload subnet. There is one template and one param file per spoke environment, with no separate test template. In both, `location` defaults to the deployment location (`-l`), and the VNet module is scoped to the resource group by name with an explicit `dependsOn` on the resource group module. Adding a spoke never touches the hub template.
- **AVM.** The templates use `br/public:avm/res/network/virtual-network`, `…/resources/resource-group`, `…/network/route-table` and `…/compute/virtual-machine`, each pinned to an exact version. Bump a module's version in every file that uses it.
- **VMs are as cheap as possible.** All VMs run Ubuntu 24.04, but the sizes differ because Azure offers different sizes per subscription, even in the same region.
  - **Router:** `Standard_B1s` (BS family, 1 vCPU, 1 GiB). The Connectivity subscription had no quota for the newer burstable families (Bsv2, Basv2, Bpsv2) but did for BS. B1s doesn't support accelerated networking, which AVM enables by default, so the router NIC sets `enableAcceleratedNetworking: false`.
  - **Spoke test VMs:** `Standard_D2pls_v6` (Dplsv6 family, 2 vCPU, 4 GiB, Arm64 Azure Cobalt 100, about $48/month) with accelerated networking on. Because it's Arm64, the image SKU is `server-arm64` (`testVmImageSku`); change both params together for an x64 size. The spoke subscriptions aren't offered the older sizes (B1s, B2s, A1_v2, F1s) in Sweden Central and have no Basv2/Bsv2 quota, but they have default Dplsv6 quota (10 vCPU). Check with `az vm list-skus -l swedencentral --size <size> --subscription <sub>` and `az vm list-usage`.
  - The VMs have a 30 GB `Standard_LRS` disk and no public IP. You manage them with `az vm run-command invoke` (or the serial console; the router has managed boot diagnostics turned on). They have no NSG. The router IP is defined in two places: `routerIpAddress` in `platform/connectivity/main.bicep` (`cidrHost(routerSubnetPrefix, 3)`) and `platform/hub.bicep`. Keep both in sync. `enableTelemetry` is set to `false`.
- **Peering lives in the landing zone.** The spoke's AVM call has one `peerings` entry with `remotePeeringEnabled: true`. AVM creates spoke → hub in the spoke resource group, and hub → spoke in a nested deployment scoped to the hub's subscription and resource group (both parsed from `hubVnetResourceId`, so the hub can be in another subscription). The identity running a landing-zone deployment needs network write access to the hub resource group as well. Attaching a VNet that wasn't created by `landing-zones/main.bicep` would need its own peering deployment.
- **Hub details come from one place.** `platform/hub.bicep` exports a `hub` object (subscription ID, resource group, VNet name and resource ID). Landing-zone param files `import { hub }` and pass `hub.vnetResourceId`. The subscription ID is a placeholder to fill in. The resource group and VNet names must match what `platform/connectivity/main.bicep` builds.
- **Each VNet template owns its VNet's subnets.** Add subnets only in the owning template, never through the portal or a PoC template. AVM deploys subnets as separate child resources, not inline in the VNet, so check with `what-if` before redeploying over a VNet that has subnets added elsewhere.
- **Naming follows the Cloud Adoption Framework (CAF)**: `<type>-<workload>-<environment>-<region>-<###>`.
  - Spokes have a required `environment` (`prod`, `dev`, `test`, `qa` or `stage`), e.g. `vnet-app1-dev-swedencentral-001` and `snet-app1-dev-swedencentral-001`. The environment is also added as a tag.
  - The hub's environment is fixed to `shared` (`vnet-hub-shared-swedencentral-001`, `snet-router-shared-…`, resource group `rg-hub-shared`) because both prod and nonprod spokes connect to it. CAF's environment list doesn't include `shared`; this is a deliberate extension so that every VNet follows the same pattern. Spokes can't use `shared`.
  - The region is the full `location` value, not an abbreviation, and `instance` defaults to `001`.
  - CAF defines no format for peerings, so they mirror its VPN connection format: `peer-<local>-to-<remote>`, with the `vnet-` prefix removed from both names (e.g. `peer-hub-shared-swedencentral-001-to-app1-dev-swedencentral-001`). The landing zone's module deployment name is cut to 64 characters with `take()`.
  - Resource groups have no region in their name. Each template creates its own: `rg-hub-shared` and `rg-spoke-<spokeName>-<environment>`, both overridable with the `resourceGroupName` param. Top-level deployment names follow the same pattern without `rg-` (`hub-shared`, `spoke-app1-dev`) and must be unique per subscription. Default subnets are the first /24 of the address space, computed with `cidrSubnet`. Each environment of a landing zone differs only by its `.bicepparam` file.
- Address plan: hub `10.0.0.0/22`, spokes consecutive /22s after it (`10.0.4.0/22`, `10.0.8.0/22`, …; the third octet is a multiple of 4). Nothing checks for overlap, so the param files have to keep spokes from colliding.
- Run landing-zone deployments one at a time. Parallel runs all modify the hub VNet's peerings and can fail with `AnotherOperationInProgress`.

## Next steps (not implemented)

Management groups and policy, pipelines with workload-identity (OIDC) service connections and `what-if` on pull requests, deployment stacks with deny settings so app teams can't remove the platform's peerings, subscription vending (`avm/ptn/lz/sub-vending`), and the Azure Landing Zones Bicep accelerator as a full reference.
