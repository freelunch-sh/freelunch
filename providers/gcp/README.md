# Google Cloud (GCP)

| | |
|---|---|
| **Status** | ✅ Implemented |
| **Category** | Hyperscalers |
| **Layer** | `host`: produces Docker hosts for the hybrid inventory |
| **Free tier** | ♾️ Always Free |
| **Terraform provider** | [`hashicorp/google`](https://registry.terraform.io/providers/hashicorp/google/latest) `>= 8.0, < 9.0` |
| **Last verified** | 2026-10-19 |

Google's Always Free tier includes one small VM that never expires. It's a 1 GB x86 host:
enough for a reverse proxy, a monitoring agent, a VPN exit node or a couple of light
containers next to a bigger OCI host. This provider creates it inside the free limits by
default.

## What's free

| Resource | Always Free allowance | Enforced by freelunch |
|---|---|---|
| Compute | **1 `e2-micro`** (2 shared vCPUs, 1 GB RAM) running all month, per billing account | ✅ (1 instance, `e2-micro` only, no Spot/preemptible) |
| Regions | `us-west1`, `us-central1`, `us-east1` | ✅ |
| Disk | **30 GB** of `pd-standard` (the console default, `pd-balanced`, is billed) | ✅ |
| Egress | 1 GB/month from North America on the free tier; Standard network tier adds 200 GB/month per region | Standard tier by default |
| External IPv4 | **Not free**: $0.005/h, about $3.65/month | ✅ needs `acknowledge_public_ipv4_charge = true` |
| Cloud Storage, Cloud Run, ... | 5 GB storage, 2M Cloud Run requests, ... | not used yet |

> **The IPv4 address costs money.** Google has billed in-use external IPv4 addresses since
> 2020 ($0.005/h since 2024-02-01), and the Always Free tier doesn't cover them. A VM
> without one has no internet access unless you add Cloud NAT, which is billed too. So
> the plan fails until you choose: set `acknowledge_public_ipv4_charge = true` to accept
> about $3.65/month, or `assign_public_ip = false`. The $300 trial credit covers the
> address for its 90 days.

Limits live in [`provider.yaml`](provider.yaml) under `limits:`. When Google changes them,
update that file; the modules read it at plan time.

## Prerequisites

1. **A Google Cloud project linked to a billing account.** The free tier still needs a
   card on file. Set a [budget alert](https://cloud.google.com/billing/docs/how-to/budgets)
   at the lowest amount.
2. **Credentials.** `gcloud auth application-default login`, or a service account key in
   `GOOGLE_APPLICATION_CREDENTIALS`. With the Docker runner, `~/.config/gcloud` is mounted
   read-only, so the application default credentials work there too.
3. **OpenTofu ≥ 1.6, Terraform ≥ 1.6, or Docker** (see the root README).

The stack enables `compute.googleapis.com` for you. Set `enable_compute_api = false` if
it's already on and your credentials can't manage services.

## Usage

```bash
cp stack/terraform.tfvars.example stack/terraform.tfvars
# set project_id, region, ssh_public_keys, acknowledge_public_ipv4_charge, and optionally apps

bin/freelunch plan gcp
bin/freelunch apply gcp
```

Or use it as a module from your own root module:

```hcl
module "gcp" {
  source = "github.com/<you>/freelunch//providers/gcp/modules/docker-host"

  region                         = "us-central1"
  ssh_public_keys                = [file("~/.ssh/id_ed25519.pub")]
  acknowledge_public_ipv4_charge = true
}
```

### Free-tier layout

There is one: `main = {}`, an `e2-micro` in zone `<region>-b` with a 30 GB `pd-standard`
disk, 2 GB of swap and a Standard-tier external IP. The usual per-instance options apply:

```hcl
instances = {
  main = {
    zone         = "us-central1-c"   # default: <region>-b
    swap_size_gb = 2
    apps = {
      whoami = {
        compose = <<-YAML
          services:
            whoami:
              image: traefik/whoami
              ports: ["80:80"]
              restart: unless-stopped
        YAML
      }
    }
  }
}
```

The allowance counts hours across the whole billing account, so if another project already
runs an `e2-micro`, this one is billed.

## What gets created

| Module | Resources |
|---|---|
| [`modules/network`](modules/network/) | Custom-mode VPC, one subnet, firewall rules (SSH from `ssh_source_cidrs`, your TCP/UDP ports, ICMP) |
| [`modules/compute`](modules/compute/) | Instances (Ubuntu 24.04 LTS image family for the machine type's architecture), free-tier guardrails |
| [`modules/docker-host`](modules/docker-host/) | Combines network + compute with [`shared/modules/docker-bootstrap`](../../shared/modules/docker-bootstrap/) |

The stack also enables the Compute Engine API. It outputs `hosts` (the
[host contract](../../docs/architecture.md#host-contract)), `ssh` commands and
`free_tier_usage` (for example `e2_micro_instances = "1/1"`).

## GCP-specific behaviour

- **SSH keys** go into instance metadata as `ubuntu:<key>`, and `enable-oslogin = FALSE`
  is set because OS Login makes an instance ignore metadata keys. If your organisation
  enforces OS Login, use `gcloud compute ssh` instead. Key changes apply in place.
- **No allow-all rules.** A GCP firewall rule without ports opens every port, so the TCP,
  UDP and SSH rules only exist when their lists are non-empty.
- **IAP.** Add `35.235.240.0/20` to `ssh_source_cidrs` to use
  `gcloud compute ssh --tunnel-through-iap`.
- **No surprise replacement.** A newer image in the Ubuntu family and edits to cloud-init
  are ignored after creation. Rebuild deliberately:
  `terraform apply -replace='module.docker_host.module.compute.google_compute_instance.this["main"]'`.
- **Shielded VM** (Secure Boot, vTPM, integrity monitoring) is on.

## Caveats

- **1 GB of RAM.** Keep the swap file, and expect image pulls and builds to be slow.
- **Egress.** The free tier itself covers 1 GB/month. Standard tier (the default here) adds
  200 GB/month per region according to Google's 2023 announcement; check the
  [network pricing](https://cloud.google.com/vpc/network-pricing) before serving much traffic.
- **Secrets in user data.** cloud-init content, including app `env` and the Tailscale key,
  is readable from instance metadata. Keep real secrets in a secrets manager.

## Tests

Offline, against a mocked Google API:

```bash
bin/freelunch test     # or: cd providers/gcp/modules/compute && terraform test
```

| Suite | Covers |
|---|---|
| `modules/compute/tests/guardrails.tftest.hcl` | Free layout passes; second instance, other regions, other machine types, `pd-balanced`, more than 30 GB and an unacknowledged IPv4 are blocked; zone must be in the region; opt-in allows Arm (`t2a`) with the arm64 image |
| `modules/docker-host/tests/network.tftest.hcl` | Every ingress port becomes a firewall rule; empty lists create no allow-all rules; valid cloud-init with swap |
| `stack/tests/plan.tftest.hcl` | Full stack plans; host contract output |

The stack has not yet been applied against a live project. If something differs from
what's described here, fix `provider.yaml` or the modules and note it.

## Roadmap

- [ ] Cloud Storage bucket (5 GB free in US regions), usable as a remote state backend
- [ ] Budget alert module
- [ ] IPv6-only option (external IPv6 is not billed)
- [ ] Cloud Run service module (2M requests/month free)

## References

Research corpus in `inspire/`. No code was copied:

- `repos/gcp/codingyoddha-gcp-free-tier-compute-terraform`: minimal free e2-micro
- `repos/multi-cloud/bodecloud-CloudBooter/cloud/GCP/docs/FREE_TIER_LIMITS.md`: limits and cost traps
- `repos/multi-cloud/gruberdev-tf-free`: multi-cloud free-tier layout
