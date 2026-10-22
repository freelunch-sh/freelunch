# Amazon Web Services (AWS)

| | |
|---|---|
| **Status** | ✅ Implemented |
| **Category** | Hyperscalers |
| **Layer** | `host`: produces Docker hosts for the hybrid inventory |
| **Free tier** | ⏳ Trial credit (Free plan, 6 months) |
| **Terraform provider** | [`hashicorp/aws`](https://registry.terraform.io/providers/hashicorp/aws/latest) `>= 6.0, < 7.0` |
| **Last verified** | 2026-10-19 |

AWS has no always-free VM. Accounts created since 2025-07-15 start on the **Free plan**:
credits for six months, limited to a short list of instance types. This provider runs
Docker hosts on those types and keeps the configuration Free plan eligible by default.
Use it as a secondary host while the credit lasts, or as a paid host on purpose.

## What's free

| Resource | Free plan (accounts created on or after 2025-07-15) | Enforced by freelunch |
|---|---|---|
| Credit | $100 at sign-up, up to $100 more from onboarding activities | n/a |
| Duration | 6 months from sign-up, or until the credit runs out | n/a |
| Instance types | `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `c7i-flex.large`, `m7i-flex.large` | ✅ |
| EBS | `gp3`/`gp2` (and magnetic types) | ✅ `gp3`/`gp2` root volumes |
| CPU credits | Burstable types default to `unlimited`, which bills sustained bursts | ✅ `standard` |
| Public IPv4 | $0.005/h (about $3.65/month), drawn from the credit | reported in `free_tier_usage` |
| Always free | Lambda 1M requests/month, DynamoDB 25 GB, CloudFront 1 TB egress | not used yet |

Everything above is paid from the credit. You can't exceed it on the Free plan: when the
plan ends, the account is suspended (data kept for 90 days) unless you upgrade. After an
upgrade, the remaining credit still applies and then usage is billed.

> **The legacy 12-month tier is gone.** The old 750 hours/month of `t2.micro`/`t3.micro`
> only applied to accounts created before 2025-07-15, and lasted 12 months, so it has
> expired for every account. Older guides still describe it.

Rough us-east-1 prices, to see how long the credit lasts:

| Layout | Per month | Fits $100 for 6 months? |
|---|---|---|
| `t3.micro` (2 vCPUs, 1 GB) + 20 GB gp3 + IPv4 (default) | about $13 | ✅ |
| `t4g.micro` (Arm, 1 GB) + 20 GB gp3 + IPv4 | about $11 | ✅ |
| `t4g.small` (Arm, 2 GB) + 20 GB gp3 + IPv4 | about $18 | only with the full $200 |

Limits live in [`provider.yaml`](provider.yaml) under `limits:`; the modules read it at plan time.

## Prerequisites

1. **An AWS account on the Free plan** (or any account, if you accept the charges). Set a
   budget alert in *Billing → Budgets*.
2. **Credentials** through the standard chain: `aws configure`, `aws sso login`, or
   `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`. Pick a profile with `aws_profile` or
   `AWS_PROFILE`. With the Docker runner, `~/.aws` is mounted read-only.
3. **OpenTofu ≥ 1.6, Terraform ≥ 1.6, or Docker** (see the root README).

## Usage

```bash
cp stack/terraform.tfvars.example stack/terraform.tfvars
# set region, ssh_public_keys, and optionally instance_type and apps

bin/freelunch plan aws
bin/freelunch apply aws
```

Or use it as a module from your own root module:

```hcl
module "aws" {
  source = "github.com/<you>/freelunch//providers/aws/modules/docker-host"

  region          = "eu-central-1"
  ssh_public_keys = [file("~/.ssh/id_ed25519.pub")]
  instances       = { main = { instance_type = "t4g.small", swap_size_gb = 0 } }
}
```

### Layouts

| Layout | `instances` |
|---|---|
| **One x86 host** (default) | `main = {}` (`t3.micro`, 20 GB gp3, 2 GB swap) |
| **One Arm host with 2 GB** | `main = { instance_type = "t4g.small", swap_size_gb = 0 }` |
| **x86 + Arm** | `x86 = {}` and `arm = { instance_type = "t4g.micro" }` (about $24/month together) |

Each instance can carry `apps`, Docker Compose files started on first boot (see the
[shared bootstrap](../../shared/modules/docker-bootstrap/)).

## What gets created

| Module | Resources |
|---|---|
| [`modules/network`](modules/network/) | VPC, internet gateway, public subnet in an AZ that offers your instance types, route table, security group (SSH from `ssh_source_cidrs`, your TCP/UDP ports, ICMP for path MTU, all egress) |
| [`modules/compute`](modules/compute/) | Instances (latest Canonical Ubuntu 24.04 AMI for each architecture), free-plan guardrails |
| [`modules/docker-host`](modules/docker-host/) | Combines network + compute with [`shared/modules/docker-bootstrap`](../../shared/modules/docker-bootstrap/) |

The stack outputs `hosts` (the [host contract](../../docs/architecture.md#host-contract)),
`ssh` commands and `free_tier_usage`.

## AWS-specific behaviour

- **SSH keys via cloud-init.** An EC2 key pair holds a single key, so every key in
  `ssh_public_keys` is installed by cloud-init for `ubuntu`. No key pair is created; the
  compute module takes `key_name` if you want one.
- **AZ placement.** Not every AZ offers every type (`us-east-1e` has no `t3` or `t4g`). The
  subnet goes to the first AZ that offers all your instance types, or `availability_zone`.
- **`standard` CPU credits.** `t3`/`t4g` launch in `unlimited` mode by default, which bills
  every vCPU-hour above baseline. freelunch sets `standard`, so bursts throttle instead.
- **IMDSv2 only**, encrypted root volumes, and `map_public_ip_on_launch = false` (each
  instance opts in with `assign_public_ip`).
- **No surprise replacement.** Newer AMIs and edits to cloud-init are ignored after
  creation. Rebuild deliberately:
  `terraform apply -replace='module.docker_host.module.compute.aws_instance.this["main"]'`.

## Caveats

- **The plan ends.** Six months after sign-up the account is suspended unless you upgrade.
  Back up anything you need before then.
- **User data is capped at 16 KB.** The plan fails above that; large Compose files belong in
  a git repo the host pulls.
- **Secrets in user data.** cloud-init content, including app `env` and the Tailscale key,
  is readable from instance metadata. Keep real secrets in a secrets manager.

## Tests

Offline, against a mocked AWS API:

```bash
bin/freelunch test     # or: cd providers/aws/modules/compute && terraform test
```

| Suite | Covers |
|---|---|
| `modules/compute/tests/guardrails.tftest.hcl` | Free plan layout passes with IMDSv2, encrypted gp3 and standard credits; Graviton gets the arm64 AMI; flex types take no credit spec; other types, `unlimited` credits, `io2` and tiny root volumes are blocked; opt-in allows other types |
| `modules/network/tests/network.tftest.hcl` | AZ chosen where every type is offered; pinned AZ wins; IPv4/IPv6 SSH sources; empty lists create no rules |
| `modules/docker-host/tests/bootstrap.tftest.hcl` | Every SSH key reaches cloud-init; swap by default |
| `stack/tests/plan.tftest.hcl` | Full stack plans; host contract output |

The stack has not yet been applied against a live account. If something differs from
what's described here, fix `provider.yaml` or the modules and note it.

## Roadmap

- [ ] Budget alert module (AWS Budgets, $1 threshold)
- [ ] IPv6-only option (no IPv4 charge)
- [ ] S3 bucket for remote state
- [ ] Always-free Lambda/DynamoDB modules

## References

Research corpus in `inspire/`. No code was copied:

- `repos/aws/pvarentsov-terraform-aws-free-tier`: free-tier VPC and EC2 layout
- `repos/aws/rogeriomm-aws-lab`: VPC, EC2 running Docker Compose, and RDS on the free tier
- `repos/multi-cloud/gruberdev-tf-free`: multi-cloud free-tier layout
