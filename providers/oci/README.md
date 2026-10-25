# Oracle Cloud Infrastructure (OCI)

| | |
|---|---|
| **Status** | ✅ Implemented |
| **Category** | Hyperscalers |
| **Layer** | `host`: produces Docker hosts for the hybrid inventory |
| **Free tier** | ♾️ Always Free |
| **Terraform provider** | [`oracle/oci`](https://registry.terraform.io/providers/oracle/oci/latest) `>= 9.0, < 10.0` |
| **Last verified** | 2026-10-18 |

OCI has the most generous always-free compute of any provider, and it's the only one where
a free VM can comfortably run several Docker apps. This provider turns it into one or more
Docker hosts that stay inside the Always Free limits by default.

## What's free

| Resource | Always Free allowance | Enforced by freelunch |
|---|---|---|
| Arm compute (`VM.Standard.A1.Flex`) | **2 OCPUs + 12 GB RAM total** (1 × 2/12 or 2 × 1/6) | ✅ |
| AMD compute (`VM.Standard.E2.1.Micro`) | 2 instances, 1/8 OCPU + 1 GB RAM each | ✅ |
| Block storage | 200 GB total across boot and block volumes | ✅ (boot volumes + `reserved_block_storage_gb`) |
| Region | Home region only | ✅ |
| Shapes | Only the two shapes above | ✅ |
| Networking | 2 VCNs, 1 flexible LB (10 Mbps), 1 NLB, 10 TB egress/month | not yet: one VCN per stack |
| Object storage | 20 GB, 50,000 requests/month | ✅ (the project's state store: `freelunch state init oci`) |
| Databases | 2 Autonomous DBs, 1 MySQL HeatWave | not used yet |

> **June 2026 change.** On 2026-06-15 Oracle quietly halved the A1 allowance from
> 4 OCPU / 24 GB to **2 OCPU / 12 GB**, and instances above it are subject to termination from
> 2026-08-18. Many guides and listings still show 4/24. freelunch blocks 4/24 unless you set
> `acknowledge_billable_resources = true`.

Limits live in [`provider.yaml`](provider.yaml) under `limits:`. When Oracle changes them,
update that file; the modules read it at plan time.

## Prerequisites

1. **An OCI account.** Sign-up needs a credit card for verification. Pick the **home region**
   carefully: you can't change it, and free resources only exist there.
2. **An API signing key.** The quickest way is the
   [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm):
   `oci setup bootstrap --profile-name freelunch` signs you in through the browser, creates
   a key, adds it to your user and writes the `freelunch` profile to `~/.oci/config`. Then
   set `oci_config_profile = "freelunch"` in the stack's tfvars. `oci setup config`, or
   *Console → My profile → API keys*, work too. With the Docker runner, use
   `key_file=~/.oci/<key>.pem` (a `~` path) in `~/.oci/config` so it also resolves inside
   the container.
3. **OpenTofu ≥ 1.6, Terraform ≥ 1.6, or Docker** (see the root README).

`oci_config_profile` picks the profile in `~/.oci/config` (default `DEFAULT`). A session
token works instead of an API key: run `oci session authenticate`, then set
`oci_auth = "SecurityToken"` and `oci_config_profile` to the profile the session was saved
under. A session token expires after an hour. `oci session refresh --profile <name>` gives
it another hour, but only while it is still valid, and only until the session ends: as many
hours after you signed in as the tenancy allows (8 in some tenancies, 24 in others).
The token says when (`sess_exp`), and `freelunch doctor` and `apply --wait-for-capacity`
show it.

freelunch refreshes the session before every plan, apply and destroy of this stack. Once
it can't be refreshed any more, the run stops before it plans anything, with one line:

```
freelunch: oci: session expired. Sign in again: oci session authenticate --profile-name <name>
```

Without the OCI CLI (in the runner image, for example), freelunch reads the expiry from the
token instead, so it still stops before planning, but it can't extend the session. With the
Docker runner, change the absolute `key_file` and `security_token_file` paths the session
wrote into `~` paths as well.

## Usage

```bash
cp stack/terraform.tfvars.example stack/terraform.tfvars
# set region (home region), tenancy_ocid, ssh_public_keys, and optionally apps

bin/freelunch plan oci
bin/freelunch apply oci
```

To serve an app through a Cloudflare Tunnel instead of open ports, set
`ingress_tcp_ports = []` and follow [docs/deploy-a-container.md](../../docs/deploy-a-container.md).
In a project, `freelunch init` starts from [`stack/project.tfvars.example`](stack/project.tfvars.example),
which is already set up that way and leaves the apps to `freelunch deploy`.

Or use it as a module from your own root module, pinned to a release:

```hcl
module "oci" {
  source = "github.com/freelunch-sh/freelunch//providers/oci/modules/docker-host?ref=v0.1.0"

  tenancy_id      = var.tenancy_ocid
  region          = "eu-frankfurt-1"
  ssh_public_keys = [file("~/.ssh/id_ed25519.pub")]
}
```

### Free-tier layouts

| Layout | `instances` | Storage used |
|---|---|---|
| **One Arm host** (default) | `main = { ocpus = 2, memory_in_gbs = 12, boot_volume_gb = 100 }` | 100 / 200 GB |
| **Arm + two micros** | `main` as above + `edge-1`, `edge-2` = `{ shape = "VM.Standard.E2.1.Micro", swap_size_gb = 2 }` | 200 / 200 GB |
| **Two small Arm nodes** | `node-1`, `node-2` = `{ ocpus = 1, memory_in_gbs = 6, boot_volume_gb = 100 }` | 200 / 200 GB |

Each instance can carry `apps`, which are Docker Compose files started on first boot:

```hcl
instances = {
  main = {
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

For a full self-hosting platform, run Dokploy or Coolify as an app and deploy everything
else through its UI (see `inspire/repos/oci-vm/statickidz-*` for reference).

### Waiting for capacity

Free A1 capacity comes and goes, and creating the host often fails with
`500-InternalError, Out of host capacity`. A plain `apply` that fails this way ends by
pointing to this command. Instead of running `apply` until it works:

```bash
bin/freelunch apply oci --wait-for-capacity
```

You review and approve the plan as usual. While OCI is out of capacity, freelunch waits two
minutes, plus up to 20% so that retries don't line up, and tries again until the host
exists. Whatever the first attempt created stays, and each retry plans again and creates
the rest. When OCI answers `TooManyRequests`, the wait doubles each time, up to 30 minutes.

**Every availability domain.** In a region with several ADs (London, Frankfurt and Ashburn
have three), each retry tries the next AD that offers the shape, round and round. Once the
host exists it stays in its AD: `availability_domain` is in `ignore_changes`, so a later
`apply` never moves or replaces it. An instance with `availability_domain_index` set is
not moved.

A retry applies its plan without asking, so it is careful about what it applies:

- Only "out of capacity", `TooManyRequests` and errors that leave nothing half done are
  retried: a 401 for clock skew (a request signed before the machine slept and sent after
  it woke), and a network failure while planning, or on a read while applying. Any other
  error stops it, a failed write among them, since what it was writing may exist.
- A plan that would destroy or replace anything stops it too. That can happen when the
  tfvars change while it waits.
- Ctrl-C stops it. When you press it during an attempt, tofu/terraform still stop
  cleanly and save the state.

Getting the host can take hours or days. `FREELUNCH_CAPACITY_INTERVAL` sets the wait in
seconds (default 120) and `FREELUNCH_CAPACITY_TIMEOUT` gives up after that many seconds.
Keep the interval at a minute or more: OCI answers faster retries with `TooManyRequests`.
This is for getting one account its free host, not for collecting hosts across accounts.

#### Review once, wait unattended

Someone has to approve the first attempt, which stops a wait in CI, a cron job or an agent
at the prompt. Review the plan once and save it instead:

```bash
freelunch plan oci --out .freelunch/oci/reviewed.tfplan
freelunch apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity
```

The first attempt applies exactly that plan, without a prompt. A retry is applied only when
every change it makes is one the reviewed plan makes too: the same resources with the same
actions. Anything else stops the wait, which then needs a new review. The plan file holds
the stack's variables and state, secrets included. `.freelunch/` ignores `*.tfplan`, and
the CLI warns about a plan file git would pick up.

An attempt that made part of the plan (the network, say, before the host ran out of
capacity) changed the state, so tofu/terraform can't apply the plan as it is any more: it is
stale. A wait you start again with the same plan goes on anyway. It plans again, and applies
only what the reviewed plan does, without a new review.

`--detach` runs the wait in the background and returns at once:

```bash
freelunch apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity --detach
freelunch status     # oci: waiting for capacity for 5h 12m, 141 attempts so far (pid 4242) ...
```

Its output goes to `.freelunch/oci/wait.log`, and `kill <pid>` stops it. `--detach` needs a
reviewed plan (or `FREELUNCH_AUTO_APPROVE=1`), since nobody would be at the prompt. A
machine that sleeps pauses the wait, and with a session token, one that sleeps for more than
an hour ends it, since the token can't be refreshed while it sleeps. On a Mac, `--detach`
runs `caffeinate -i -w <pid>`, which keeps the Mac awake until the wait ends (closing the
lid still puts it to sleep). Elsewhere, keep the machine awake yourself.

#### A machine that stays on

A wait needs a machine that stays on for as long as it takes, which can be days. A laptop
with its lid closed makes no attempts, and wakes now and then for a minute; the wait says
so when it notices the machine slept. Hand the wait to GitHub Actions instead, with the same
reviewed plan:

```bash
freelunch ci wait oci --plan .freelunch/oci/reviewed.tfplan
```

That takes the project's state in a store both reach (`freelunch state init oci` puts it in
your tenancy's Object Storage) and the workflows from `freelunch ci init`. Each scheduled
run makes one attempt, in the next availability domain, until the host exists. A machine of
your own that stays on works as well. [Run freelunch from CI](../../docs/ci.md) has both.

When a wait in the background ends, or a wait that had to retry, freelunch sends a desktop
notification (macOS, or Linux with `notify-send`). Set `FREELUNCH_NOTIFY` in `.freelunch/.env`
to get it on your phone too: an [ntfy](https://ntfy.sh) topic URL
(`https://ntfy.sh/<a-topic-only-you-know>`), or a Discord or Slack webhook URL.
`FREELUNCH_NOTIFY=off` turns notifications off.

**With a session token** (`oci_auth = "SecurityToken"`), freelunch runs
`oci session refresh --profile <oci_config_profile>` before every attempt, so it needs the
[OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm). That
keeps the session going until it ends, which the wait prints when it starts and
`freelunch status` shows. When a refresh fails, the retries stop and print the command to
sign in again
(`oci session authenticate --profile-name <name>`); run `apply` again after it. For a
longer wait, use an API key, which doesn't expire (`oci setup bootstrap`, see
[Prerequisites](#prerequisites)). The runner image has no OCI CLI, so there it takes an
API key.

## What gets created

| Module | Resources |
|---|---|
| [`modules/network`](modules/network/) | VCN, internet gateway, route table, security list (SSH from `ssh_source_cidrs`, your TCP/UDP ports, ICMP for path MTU), public subnet |
| [`modules/compute`](modules/compute/) | Instances (latest Ubuntu 24.04 for each shape), free-tier guardrails, automatic availability-domain placement |
| [`modules/docker-host`](modules/docker-host/) | Combines network + compute with [`shared/modules/docker-bootstrap`](../../shared/modules/docker-bootstrap/) and OCI's host-firewall fix |

The stack outputs `hosts` (the [host contract](../../docs/architecture.md#host-contract)),
`ssh` commands and `free_tier_usage` (for example `a1_ocpus = "2/2"`).

## OCI-specific behaviour

- **Host firewall.** Oracle's Ubuntu images ship iptables rules that reject inbound traffic
  even when the VCN allows it. Each ingress port is opened live and written into
  `/etc/iptables/rules.v4`, without `netfilter-persistent save`, which would also capture
  Docker's chains and break container networking after a reboot.
- **Availability domains.** The micro shape exists in only one AD in multi-AD regions.
  The compute module finds an AD that offers each shape, and `apply --wait-for-capacity`
  moves to the next one on each retry (`availability_domain_offset`). Set
  `availability_domain_index` to pin one. A created instance never changes AD.
- **No surprise replacement.** Platform-image updates and edits to cloud-init/SSH keys are
  ignored after creation, and so is a new VCN DNS label: OCI can't change one, so setting
  `name_prefix` on a project that has its network already would replace the VCN and the
  hosts in it. The network and hosts are renamed in place instead and keep the old label. Recreating an A1 instance can fail for days on capacity, so a
  rebuild has to be deliberate: `terraform apply -replace='module.docker_host.module.compute.oci_core_instance.this["main"]'`.
- **IMDSv1 disabled** (`are_legacy_imds_endpoints_disabled = true`).
- **Host hardening** comes from the shared bootstrap: SSH keys only, rotated Docker logs,
  and a 04:00 UTC reboot when a security update needs one.

## Caveats

- **The tenancy's limits count every project in it.** Two VCNs are free, and the A1 cores of
  any other instance count against the same Always Free allowance. `freelunch doctor` asks
  OCI's limits API how many VCNs and A1 cores are left before you apply. OCI goes on
  counting a deleted VCN for a few minutes, so a plan that replaces the network on a full
  tenancy fails; `plan --out` warns about that, and `freelunch destroy oci`, then a new plan
  a few minutes later, gets around it.

- **"Out of host capacity"** on A1 creation is common. `apply oci --wait-for-capacity`
  keeps trying until the host exists (see [Waiting for capacity](#waiting-for-capacity)).
  Upgrading to Pay-As-You-Go improves capacity, but then anything over the caps is billed,
  so set a $1 budget alert first.
- **Idle reclamation.** Oracle may reclaim Always Free instances whose CPU, network and (for A1)
  memory stay under ~20% at the 95th percentile for 7 days. Run real workloads. Synthetic load
  generators break the spirit of the free tier.
- **Secrets in user data.** cloud-init content, including app `env` and the Tailscale key,
  is readable from instance metadata. Keep real secrets out of it: `freelunch deploy`
  copies app secrets over SSH, and a one-off Tailscale key is worthless once used.
- **Home region check.** The precondition compares `region` with the tenancy's home region,
  so the API key needs permission to list region subscriptions.

## Tests

Offline, against a mocked OCI API:

```bash
bin/freelunch test     # or: cd providers/oci/modules/compute && terraform test
```

| Suite | Covers |
|---|---|
| `modules/compute/tests/guardrails.tftest.hcl` | Maximum free layout passes; legacy 4/24, 3rd micro, over-200 GB, paid shapes and non-home region are blocked; opt-in allows overage; AD auto-placement, and the offset that moves to the next AD |
| `modules/docker-host/tests/firewall.tftest.hcl` | Every ingress port reaches the host firewall; no `netfilter-persistent save`; valid YAML |
| `modules/network/tests/ingress.tftest.hcl` | With no ingress ports (Tunnel layout) only SSH and path-MTU ICMP are allowed in; default ports open |
| `stack/tests/plan.tftest.hcl` | Full stack plans; host contract output; arch per shape |

## Roadmap

- [ ] Block volume module (attach + mount the rest of the 200 GB)
- [ ] Reserved public IP option
- [x] Object Storage bucket for the project's state (`freelunch state init oci`, through the S3-compatible API)
- [ ] Budget alert module ($1 threshold)
- [ ] Always Free Autonomous DB / MySQL HeatWave modules
- [ ] k3s cluster layout (see `inspire/repos/oci-kubernetes`)

## References

Research corpus in `inspire/`. Ideas were taken from these repos; no code was copied:

- `repos/oci-vm/filippolmt-terraform-oci-free-tier`: free-cap guardrails and design notes (GPL, ideas only)
- `repos/oci-vm/briansunter-oracle-world`: module structure, host firewall handling (MIT)
- `repos/oci-vm/RhubarbSin-terraform-oci-free-compute-maximal-example`: maximal free layout (MIT)
- `repos/oci-kubernetes/dorukgezici-k3s-oci-always-free`: OCI + Cloudflare + Tailscale, recovery from reclaim (MIT)
- `repos/oci-capacity/*`: capacity retry approaches
- `repos/multi-cloud/bodecloud-CloudBooter/cloud/OCI/docs/FREE_TIER_LIMITS.md`: limits and PAYG safety
