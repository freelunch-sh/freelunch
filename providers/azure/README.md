# Microsoft Azure

| | |
|---|---|
| **Status** | ✅ Implemented |
| **Category** | Hyperscalers |
| **Layer** | `host`: produces Docker hosts for the hybrid inventory |
| **Free tier** | ⏳ $200 credit for 30 days, then 12 months of free services |
| **Terraform provider** | [`hashicorp/azurerm`](https://registry.terraform.io/providers/hashicorp/azurerm/latest) `>= 5.0, < 6.0` |
| **Last verified** | 2026-10-19 |

A new Azure account gets 12 months of free VM hours on three small burstable sizes, one
of them Arm, plus two 64 GB Premium SSDs. That's enough for two 1 GiB Docker hosts for a
year. This provider creates them inside those limits by default.

## What's free

| Resource | 12-month free services | Enforced by freelunch |
|---|---|---|
| VMs | **750 hours/month each** of `Standard_B1s` (1 vCPU), `Standard_B2pts_v2` (2 vCPUs, Arm) and `Standard_B2ats_v2` (2 vCPUs, AMD), all 1 GiB | ✅ free sizes only, one VM per size |
| Managed disks | **2 × P6** (64 GiB Premium SSD) | ✅ ≤ 2 VMs, OS disk `Premium_LRS` 33-64 GB |
| Public IPv4 | **Not free**: Standard static, about $3.65/month | ✅ needs `acknowledge_public_ipv4_charge = true` |
| Regions | Any region that offers the size | n/a |
| Credit | $200 for the first 30 days, for anything | n/a |

> **The IPv4 address costs money.** Basic SKU public IPs, which had a free allowance, were
> retired on 2025-09-30, and Standard IPv4 addresses are billed. New subnets also have no
> default outbound access, so a VM without a public IP can't reach the internet without a
> NAT gateway (billed too). The plan fails until you choose: set
> `acknowledge_public_ipv4_charge = true` to accept about $3.65/month per VM, or
> `assign_public_ip = false`. The $200 credit covers it for the first 30 days.

> **Disk size matters.** Premium SSD bills by tier. A disk of 32 GB or less is a P4, which is
> not in the free offer. freelunch defaults to 64 GB, the full P6.

After 30 days (or once the credit is used) the subscription is disabled unless you upgrade
to pay-as-you-go. The 12-month services continue after the upgrade; anything else, and
everything after 12 months, is billed.

Limits live in [`provider.yaml`](provider.yaml) under `limits:`; the modules read it at plan time.

## Prerequisites

1. **An Azure free account** (card, phone number and a $1 authorisation hold). Set a
   budget in *Cost Management → Budgets*.
2. **Credentials.** `az login` locally, or a service principal through `ARM_CLIENT_ID`,
   `ARM_CLIENT_SECRET` and `ARM_TENANT_ID`. The Docker runner has no Azure CLI, so put
   the service principal variables in `.env` there.
3. **The subscription ID** in `subscription_id` or `ARM_SUBSCRIPTION_ID`
   (`az account show --query id -o tsv`).
4. **OpenTofu ≥ 1.6, Terraform ≥ 1.6, or Docker** (see the root README).

## Usage

```bash
cp stack/terraform.tfvars.example stack/terraform.tfvars
# set subscription_id, location, ssh_public_keys, acknowledge_public_ipv4_charge, and optionally apps

bin/freelunch plan azure
bin/freelunch apply azure
```

Or use it as a module from your own root module:

```hcl
module "azure" {
  source = "github.com/<you>/freelunch//providers/azure/modules/docker-host"

  location                       = "westeurope"
  ssh_public_keys                = [file("~/.ssh/id_ed25519.pub")]
  acknowledge_public_ipv4_charge = true
}
```

### Free-tier layouts

| Layout | `instances` | Disks used |
|---|---|---|
| **One AMD host** (default) | `main = {}` (`Standard_B2ats_v2`, 64 GB P6, 2 GB swap) | 1 / 2 |
| **AMD + Arm** | `amd = { size = "Standard_B2ats_v2" }`, `arm = { size = "Standard_B2pts_v2" }` | 2 / 2 |

A third VM (`Standard_B1s`) would have its own free hours but needs a third disk, which is
billed. Check that your region offers the sizes, especially the Arm `B2pts_v2`:
`az vm list-skus --location <region> --size Standard_B2 --output table`.

## What gets created

| Module | Resources |
|---|---|
| [`modules/network`](modules/network/) | Virtual network, subnet, network security group (SSH from `ssh_source_cidrs`, your TCP/UDP ports, ICMP) attached to the subnet |
| [`modules/compute`](modules/compute/) | Standard public IPs, NICs, Linux VMs (Ubuntu 24.04 LTS for each architecture), free-tier guardrails |
| [`modules/docker-host`](modules/docker-host/) | A resource group (`<name_prefix>-rg`) plus network + compute with [`shared/modules/docker-bootstrap`](../../shared/modules/docker-bootstrap/) |

The stack outputs `hosts` (the [host contract](../../docs/architecture.md#host-contract)),
`ssh` commands and `free_tier_usage` (for example `p6_disks = "1/2"`).

## Azure-specific behaviour

- **Login user** is `azureuser` (`admin_username`), with password authentication disabled.
  RSA (≥ 2048 bits) and Ed25519 keys both work.
- **Architecture from the size.** Arm sizes (a `p` in the feature letters, such as
  `B2pts_v2`) boot the `server-arm64` Ubuntu image; the rest boot `server`.
- **NSG before boot.** The subnet ID handed to the VMs comes from the NSG association, so
  no VM boots before its rules are attached.
- **No surprise replacement.** Changing cloud-init or SSH keys would replace a VM in
  Azure, so both are ignored after creation. Rebuild deliberately:
  `terraform apply -replace='module.docker_host.module.compute.azurerm_linux_virtual_machine.this["main"]'`.

## Caveats

- **1 GiB of RAM** on every free size. Keep the swap file.
- **Credits run out after 30 days.** Upgrade to pay-as-you-go before then, or the
  subscription is disabled and the VMs stop.
- **12 months.** When the free services expire, the VMs, disks and IPs keep running and
  are billed. Destroy the stack or resize before then.
- **Secrets in custom data.** cloud-init content, including app `env` and the Tailscale key,
  is readable from the VM. Keep real secrets in a secrets manager.

## Tests

Offline, against a mocked Azure API (azurerm still validates SSH keys, so the tests use a
throwaway Ed25519 key):

```bash
bin/freelunch test     # or: cd providers/azure/modules/compute && terraform test
```

| Suite | Covers |
|---|---|
| `modules/compute/tests/guardrails.tftest.hcl` | AMD + Arm layout uses both P6 disks with the right images; two VMs of one size, a third VM, paid sizes, P4-sized and Standard SSD disks and an unacknowledged IPv4 are blocked; opt-in allows other sizes |
| `modules/network/tests/nsg.tftest.hcl` | SSH sources and ports become NSG rules; empty lists create none |
| `modules/docker-host/tests/bootstrap.tftest.hcl` | The admin user joins the docker group; resource group naming |
| `stack/tests/plan.tftest.hcl` | Full stack plans; host contract output |

The stack has not yet been applied against a live subscription. If something differs from
what's described here, fix `provider.yaml` or the modules and note it.

## Roadmap

- [ ] Budget alert module
- [ ] IPv6 option (Azure public IPv6 addresses are free)
- [ ] Storage account for remote state (5 GB LRS blob free for 12 months)
- [ ] Always-free Container Apps / Functions modules

## References

Research corpus in `inspire/`. No code was copied:

- `repos/azure/xRizur-terraform-azure-free-app-stack`: App Service F1, free Cosmos DB and Key Vault, with free-SKU enforcement
- `repos/azure/SalesFX-aks-free-tier-terraform`: AKS free control-plane tier with ingress and KEDA
- `repos/multi-cloud/gruberdev-tf-free`: multi-cloud free-tier layout
