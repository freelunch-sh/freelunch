# freelunch

**Free infrastructure as code.** Terraform/OpenTofu modules for every cloud provider's free tier,
one folder per provider. Use one provider on its own, or combine them into a hybrid setup:
an Arm VM on Oracle, a micro VM on Google, a container on Northflank, a Postgres on Neon, DNS
and tunnels on Cloudflare, all joined in one inventory. Then deploy your project's containers
onto it from your own repository, and move them to another provider by changing one name.

> **Status:** early. Four hyperscalers are implemented (Oracle Cloud, Google Cloud, AWS and
> Azure), Northflank for containers without a VM, and Cloudflare for tunnels and DNS, each
> with offline test suites. GCP, AWS, Azure and Northflank have not been used against live
> accounts yet. Every other provider is catalogued with its free tier, Terraform provider
> and a plan. See the [checklist](#provider-checklist) and the [roadmap](#roadmap).

## Principles

- **Free by default, paid only on purpose.** Each provider's free-tier limits live in its
  `provider.yaml`, and modules enforce them with preconditions. Going over a limit means
  setting `acknowledge_billable_resources = true`. When a free VM still needs a billed
  extra (the public IPv4 address on GCP and Azure), the plan fails until you accept it with
  `acknowledge_public_ipv4_charge = true`.
- **One folder per provider, each usable on its own.** `providers/<name>/` holds that
  provider's README, metadata, modules and a deployable stack.
- **Hybrid by composition.** Every compute provider outputs the same
  [host contract](docs/architecture.md#host-contract), and every container platform the same
  [platform contract](docs/architecture.md#platform-contract). `hybrid/` merges whatever is
  deployed into one inventory (Ansible, SSH config, JSON), and edge providers such as
  Cloudflare build on it, so moving an app is changing the name of its target.
- **Docker-first workloads.** Hosts boot with Docker and Compose through one shared cloud-init
  module, so an app deploys the same way on any cloud, and a container platform runs the
  same Compose file.
- **Respect provider terms.** No automated account creation, no idle-reclaim dodging, no
  multi-account farming.

## How it works

```
providers/oci/stack        ─┐                          ┌─> inventory.json / ansible / ssh_config
providers/gcp/stack        ─┤                          │
providers/aws/stack        ─┼─> hybrid/ (reads state) ─┤
providers/azure/stack      ─┤   hosts and platforms    └─> glue stacks: cloudflare (DNS, tunnels), tailscale (ACLs)
providers/northflank/stack ─┘

providers/neon/stack, providers/upstash/stack, ...   standalone services (databases, storage, monitoring)
```

Each provider stack has its own state, credentials and lifecycle, so OCI being out of
capacity never blocks GCP, and you never need AWS credentials just to deploy to Oracle.
`freelunch deploy` then copies your Compose apps to the hosts over SSH, or on a container
platform turns each one into a service through the platform's API.
Read [docs/architecture.md](docs/architecture.md) for the reasoning.

## Quick start: deploy your project

Put your backend's container on an Always Free Oracle Cloud VM and serve it at
`https://api.example.com` through a Cloudflare Tunnel, with no port open except SSH.
freelunch is a command you install once. Your repository gets only a `.freelunch/` folder
with its config, and `.freelunch/version` pins the freelunch it runs, so every machine and CI
job runs the same one.

The domain can be free too. `freelunch domain suggest myapp` finds free names like
`myapp.dpdns.org` at each [free domain provider](#provider-checklist), the recommended one
first. `freelunch domain add` puts the one you register on Cloudflare and `domain status`
says when it's ready ([docs/free-domains.md](docs/free-domains.md)).

```bash
curl -fsSL https://raw.githubusercontent.com/freelunch-sh/freelunch/main/install.sh | bash

cd your-project
freelunch init                 # creates .freelunch/: tfvars examples, apps.tfvars, the version
# fill in .freelunch/oci/terraform.tfvars, .freelunch/cloudflare/terraform.tfvars, .freelunch/.env
freelunch apply oci            # the VM, with Docker
freelunch apply cloudflare     # tunnel + DNS record
freelunch deploy               # copy compose files and secrets, start, wait until healthy
```

If OCI is out of Arm capacity, `freelunch apply oci --wait-for-capacity` keeps trying, in
every availability domain, until the VM exists; with a reviewed plan it can wait in the
background and notify you. That can take days, longer than a laptop stays awake, so
`freelunch ci wait` hands the wait to GitHub Actions instead, which also deploys each new
image ([docs/ci.md](docs/ci.md)). No capacity, or no wish to run a VM? Northflank's free plan runs
the same app, without a card, as two always-on services: your app and `cloudflared`
([switch to another provider](docs/deploy-a-container.md#switch-to-another-provider)).

To ship a new version, change the image tag and run `freelunch deploy` again; the VM stays.
`freelunch upgrade` moves the project to the latest freelunch release.

In GitHub Actions, the [Run freelunch](action.yml) action runs any command with the version
the project pins; `freelunch ci init` writes the workflows:

```yaml
- uses: actions/checkout@v7
- uses: freelunch-sh/freelunch@v0.1.0
  with:
    run: deploy
    bundle: ${{ secrets.FREELUNCH_BUNDLE }}
```

Without installing anything but Docker:

```bash
docker run --rm -it -v "$PWD:/project" -v ~/.oci:/root/.oci:ro \
  -v ~/.ssh/id_ed25519:/root/.ssh/id_ed25519:ro -e FREELUNCH_SSH_KEY=/root/.ssh/id_ed25519 \
  ghcr.io/freelunch-sh/freelunch:0.1.0 deploy
```

The full walkthrough, with private images, secrets and persistent data, is
[docs/deploy-a-container.md](docs/deploy-a-container.md). A finished project is in
[examples/backend-app](examples/backend-app/).

## Quick start inside this checkout (OCI)

To try a provider without a project of your own, run the stacks from the checkout.
Prerequisites: an OCI account, an [API signing key](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/apisigningkey.htm)
in `~/.oci/config` (`oci setup bootstrap` creates one), and either Docker or OpenTofu/Terraform.

```bash
cp providers/oci/stack/terraform.tfvars.example providers/oci/stack/terraform.tfvars
$EDITOR providers/oci/stack/terraform.tfvars      # home region, tenancy OCID, SSH key, apps

# with Docker (pins OpenTofu, needs nothing else)
docker compose run --rm freelunch plan oci
docker compose run --rm freelunch apply oci

# or with a local tofu/terraform
bin/freelunch plan oci
bin/freelunch apply oci
```

`apply` prints the hybrid inventory when it finishes. `bin/freelunch inventory` writes
`inventory.json`. Full details, free-tier layouts and caveats are in [providers/oci](providers/oci/).

## Other hosts and platforms

GCP, AWS and Azure work the same way as OCI: copy `stack/terraform.tfvars.example` to
`stack/terraform.tfvars`, fill it in, then `bin/freelunch plan <provider>`. Each stack outputs
the same `hosts` list, so they join the OCI host in one inventory. Northflank is a container
platform: there is no VM, and `deploy` puts each app there as a service through its API. A
project moves between them by changing its target's name in `apps.tfvars` and the routes
([how](docs/deploy-a-container.md#switch-to-another-provider)).

> **Not live-tested yet.** The GCP, AWS, Azure and Northflank stacks pass their offline tests
> but have not been used against real accounts. Read the plan before you apply, and please
> open an issue with what you find.

| Provider | Free host by default | Credentials | What costs money |
|---|---|---|---|
| [OCI](providers/oci/) | 1 Arm VM, 2 OCPUs / 12 GB, 100 GB disk (always free) | `~/.oci/config` | nothing in the default layout |
| [GCP](providers/gcp/) | 1 `e2-micro`, 1 GB, 30 GB disk in us-west1/us-central1/us-east1 (always free) | `gcloud auth application-default login` | external IPv4, about $3.65/month |
| [AWS](providers/aws/) | 1 `t3.micro`, 1 GB, 20 GB gp3 on the Free plan (6 months) | `~/.aws` / `AWS_PROFILE` | everything draws on the credit, about $13/month |
| [Azure](providers/azure/) | 1 `B2ats_v2`, 1 GiB, 64 GB P6 disk (12 months; a second, Arm host also fits) | `az login` or `ARM_*` | public IPv4, about $3.65/month per VM |
| [Northflank](providers/northflank/) | 2 always-on services of up to 0.2 vCPU and 512 MB: your app and `cloudflared` (no card) | `NORTHFLANK_API_TOKEN` | nothing on the Sandbox plan |

```bash
bin/freelunch plan gcp aws azure
bin/freelunch apply all            # every ready provider with a terraform.tfvars
bin/freelunch inventory            # hosts from every cloud in one inventory.json
```

## CLI

| Command | What it does |
|---|---|
| `freelunch init [--name <name>] [--image-workflow] [stack...]` | Create `.freelunch/` in your project (default stacks: `oci cloudflare`), with resources named after the project. `--image-workflow` adds a GitHub Actions workflow that builds your image for the hosts and pushes it to GHCR |
| `freelunch deploy [host\|provider]` | Check that every image has a build for its host, copy Compose apps and their secrets to the hosts over SSH, start them, wait until healthy, start `cloudflared` (`--dry-run` to preview). On a container platform (Northflank) each app becomes a service through its API instead |
| `freelunch trust <host>` | Pin an OCI host's SSH keys in `known_hosts` from its serial console before the first deploy, and check that the host answers with one of them |
| `freelunch domain suggest <name...>` | Whether the name you typed is registered, then free names like it at every free domain provider, and similar ones where yours is taken ([docs/free-domains.md](docs/free-domains.md)) |
| `freelunch domain add\|status <name>` | Put the name on Cloudflare and print the nameservers to set at its provider; say when they are set and the zone is active |
| `freelunch state [push\|pull]`, `state init <store>` | Keep an encrypted copy of every stack's state where CI and your other machines reach it: OCI Object Storage (`state init oci` makes the bucket), R2, B2 or GitLab. Commands copy it on their own ([docs/ci.md](docs/ci.md#1-keep-the-state-in-a-store)) |
| `freelunch ci init\|secrets\|wait` | Run the project from CI: workflows that wait for capacity on a schedule and deploy each new image, the secret `FREELUNCH_BUNDLE` with what git doesn't have, and a wait for capacity handed to GitHub Actions with the plan you reviewed ([docs/ci.md](docs/ci.md)) |
| `freelunch list` | Every provider with category, status, layer, IaC support and deployment state |
| `freelunch plan\|apply\|destroy <p...\|all>` | Run provider stacks in layer order (hosts and platforms → services → hybrid → glue). A platform's `apply` makes the target there (the Northflank project) and `destroy` deletes it with what `deploy` put in it. `plan --show-user-data` prints each host's cloud-init with secrets left out, `plan --out <file>` saves a plan and `apply --plan <file>` applies it without a prompt. `apply --wait-for-capacity` retries hosts while OCI is out of capacity, `--detach` in the background ([how](providers/oci/README.md#waiting-for-capacity)) |
| `freelunch status` | One screen after setup: hosts and platforms, the apps on each one and whether they run, tunnels and their URLs, service token expiry, capacity waits |
| `freelunch doctor` | Check what plan, apply and deploy will need before they run: tools, the OCI sign-in, home region and the VCNs and A1 cores the tenancy has left, the Northflank token, region and project, SSH keys, images and registry logins, the Cloudflare token, its permissions and the zone. It changes nothing |
| `freelunch hybrid` | Re-aggregate deployed host and platform stacks |
| `freelunch inventory` | Write `inventory.json` |
| `freelunch output <stack> [name]` | Print a stack's outputs from its state, e.g. `output cloudflare -json service_tokens` or `output hybrid -raw ssh_config` |
| `freelunch catalog` | Regenerate the checklist below and the stub provider READMEs from `provider.yaml` files |
| `freelunch test` | Run all offline test suites (mocked providers, fake ssh and docker, no credentials) |
| `freelunch fmt [-check]` | Format all HCL, or check it |

`freelunch` is `bin/freelunch` in a checkout. In a directory with a `.freelunch/` folder it
reads and writes config and state there; elsewhere in the checkout it uses each
`providers/<name>/stack/`. Credentials come from your shell or `.freelunch/.env`, where a
value can also name a secret in 1Password (`op://...`) or the macOS keychain
(`keychain:<name>`). `all` means every `ready` provider that has a `terraform.tfvars`.

## Repository layout

```
freelunch/
├── bin/freelunch                  CLI (bash; uses tofu or terraform)
├── action.yml                     the GitHub Action that projects' workflows run freelunch with
├── Dockerfile, compose.yaml       runner image (published to GHCR) and a dev runner for this checkout
├── providers/
│   ├── _template/                 starting point for a new provider
│   ├── oci/                       ✅ implemented
│   │   ├── README.md              provider guide
│   │   ├── provider.yaml          metadata + free-tier limits (enforced)
│   │   ├── modules/               network, compute, docker-host
│   │   └── stack/                 deployable root module (+ tests)
│   ├── gcp/, aws/, azure/         ✅ implemented, same layout as oci/
│   ├── northflank/                ✅ container platform: a project per freelunch project, apps deployed through its API
│   ├── cloudflare/                ✅ glue: tunnel, DNS and Access per host, plus the cloudflared app
│   └── <provider>/                provider.yaml + README for every catalogued provider
├── shared/modules/docker-bootstrap  provider-agnostic cloud-init: Docker, Compose apps, swap, Tailscale, hardening
├── hybrid/                        merges every deployed host stack into one inventory
├── deploy/                        resolves a project's apps.tfvars into a deploy plan per host
├── catalog/                       renders the checklist from providers/*/provider.yaml
├── examples/backend-app/          a project that deploys one container behind a tunnel
├── tests/cli.sh                   offline tests for init, project state, deploy and domain suggest
├── docs/                          architecture, deploying a container, running it from CI, free domains, adding a provider
└── inspire/                       local research corpus (git-ignored, not published)
```

## Roadmap

Releases are small: every usable feature gets its own tag. Versions stay at 0.x until every
part has been used against real accounts; 1.0 comes after that, and from then on a release
doesn't break your project.

- **v0.1 (next release), deploy your project from its own repo:** install freelunch once and pin its
  version in each project (or use the versioned Docker image), keep config and state in that project, put its
  Docker image (public or from a private registry) on an always-free host (an Oracle VM, or
  Northflank's free plan when Oracle has no capacity), reach it at
  `https://api.example.com` through a Cloudflare Tunnel and DNS, and ship new versions with
  `freelunch deploy` without replacing the VM.
- **On main since:** run the project from CI and other machines: an encrypted copy of
  the state in a store, a GitHub Action, and a wait for capacity in GitHub Actions
  ([docs/ci.md](docs/ci.md)).
- **Next, in order:**
  1. **Menus:** ready-made stacks in one command, starting with the v0.1 setup.
  2. **$0 guardrails:** a budget alert on every provider and a cost summary after each plan.
  3. **Health alerts** for hosts and apps.
  4. **Backups** to R2 or B2, with restore.
  5. **`freelunch doctor`, continued:** billable leftovers, expiring trials and free names.
- **Later:** more menus (self-hosted PaaS, homelab, k3s, VPN, n8n, CI runners, game
  servers), moving a host to another cloud with its data, secrets managers, more container
  platforms (Cloud Run, Scaleway, Koyeb, Render) and GPU providers, and a linter that flags
  billable resources in any Terraform repo.

Ideas and requests are welcome as issues.

## Provider checklist

The checklist is generated from `providers/*/provider.yaml` (`bin/freelunch catalog`).
A box is checked once the provider has tested modules and a stack. The free-tier summaries
were verified on the dates in each `provider.yaml`. Free tiers change often, so check
the provider's page before relying on one.

<!-- BEGIN PROVIDER CHECKLIST -->
<!-- Generated by `bin/freelunch catalog` from providers/*/provider.yaml. Edit those files, not this block. -->
**10 of 122 providers implemented** · 99 can be managed with a maintained Terraform/OpenTofu provider

**Legend:** checked = implemented in freelunch · **recommended** = the one to start with where a section has several ·
🟢 official/partner Terraform provider · 🟡 community provider · 🟠 provider exists but is stale · ⚪ no Terraform provider (API/CLI only) ·
♾️ always free · 🔁 monthly credit · ⏳ trial credit · 🎓 startup/research programs · 💲 paid only

### Hyperscalers (4/8)

Large public clouds. Only OCI and GCP give always-free VMs; Azure gives new accounts 12 months of small VMs, and AWS a 6-month credit.

- [ ] **[Alibaba Cloud](providers/alibaba-cloud/)** 🟢 `aliyun/alicloud` · ⏳ Free trials of selected products for new accounts; startup credit programs
- [x] **[Amazon Web Services](providers/aws/)** 🟢 `hashicorp/aws` · ⏳ New accounts (since 2025-07-15): up to $200 credit on the Free plan, which ends after 6 months; always-free Lambda 1M requests/month, DynamoDB 25 GB, CloudFront 1 TB egress
- [x] **[Google Cloud](providers/gcp/)** 🟢 `hashicorp/google` · ♾️ 1 e2-micro VM (us-west1, us-central1 or us-east1) with 30 GB standard disk, 5 GB Cloud Storage, Cloud Run 2M requests + 180k vCPU-s/month; $300 trial credit for 90 days
- [ ] **[Huawei Cloud](providers/huawei-cloud/)** 🟡 `huaweicloud/huaweicloud` · ⏳ Free trial packages for new accounts; free DNS hosting; startup program
- [ ] **[IBM Cloud](providers/ibm-cloud/)** 🟢 `IBM-Cloud/ibm` · ♾️ Lite plans: Cloudant 1 GB, Db2 100 MB, API Connect 50k calls/month, Log Analysis 500 MB/day
- [x] **[Microsoft Azure](providers/azure/)** 🟢 `hashicorp/azurerm` · ⏳ $200 credit for 30 days; 12 months: 750 h each of B1s, B2pts v2 (Arm) and B2ats v2 (AMD) VMs, 2 × 64 GB P6 SSD disks; always free: App Service F1 (10 apps), Functions 1M requests, Container Apps 180k vCPU-s + 2M requests, Cosmos DB 25 GB
- [x] **[Oracle Cloud (OCI)](providers/oci/)** 🟢 `oracle/oci` · ♾️ 2 Arm A1 OCPUs + 12 GB RAM, 2 AMD micro VMs, 200 GB block storage, 10 TB egress/month, 2 VCNs, 1 flexible load balancer, 20 GB object storage; home region only
- [ ] **[Tencent Cloud](providers/tencent-cloud/)** 🟢 `tencentcloudstack/tencentcloud` · ⏳ Free trial packages for new accounts; startup program

### VPS & cloud credits (0/10)

Developer clouds with trial credits or low-cost VMs: secondary hosts while credits last, and paid fallbacks.

- [ ] **[Akamai Cloud (Linode)](providers/linode/)** 🟢 `linode/linode` · ⏳ $100 trial credit for new customers; Rise startup program
- [ ] **[Civo](providers/civo/)** 🟢 `civo/civo` · ⏳ $250 trial credit; managed k3s clusters
- [ ] **[Contabo](providers/contabo/)** 🟡 `contabo/contabo` · 💲 No free tier; low-cost VPS
- [ ] **[DigitalOcean](providers/digitalocean/)** 🟢 `digitalocean/digitalocean` · ⏳ $200 credit for 60 days for new users; App Platform: 3 static sites free; open-source credits program
- [ ] **[Exoscale](providers/exoscale/)** 🟢 `exoscale/exoscale` · 💲 No free tier found during research; paid European cloud
- [ ] **[Hetzner Cloud](providers/hetzner/)** 🟢 `hetznercloud/hcloud` · 💲 No free compute; low-cost Arm and x86 VMs; free DNS zones (managed by the same provider via hcloud_zone)
- [ ] **[IONOS Cloud](providers/ionos/)** 🟢 `ionos-cloud/ionoscloud` · ⏳ Time-limited trial for new accounts
- [ ] **[OVHcloud](providers/ovhcloud/)** 🟢 `ovh/ovh` · 🎓 No always-free compute; Startup Program (up to EUR 100K for EU scale-ups)
- [ ] **[UpCloud](providers/upcloud/)** 🟢 `UpCloudLtd/upcloud` · ⏳ Time-limited free trial for new accounts
- [ ] **[Vultr](providers/vultr/)** 🟢 `vultr/vultr` · ⏳ $250 free credit program for new accounts (time-limited)

### GPU compute (0/11)

GPU VMs and clusters. Almost none are free; access comes through startup or research programs or per-second billing. Catalogued so GPU capacity can join a hybrid setup the same way as CPU hosts.

- [ ] **[CoreWeave](providers/coreweave/)** 🟢 `coreweave/coreweave` · 💲 No free tier; GPU Kubernetes clusters with sales-led onboarding
- [ ] **[Crusoe Cloud](providers/crusoe/)** 🟡 `crusoecloud/crusoe` · 💲 No free tier; no egress fees
- [ ] **[Genesis Cloud](providers/genesis-cloud/)** 🟢 `genesiscloud/genesiscloud` · 💲 No free tier found during research
- [ ] **[Hyperstack](providers/hyperstack/)** 🟡 `NexGenCloud/hyperstack` · 💲 No free tier found during research
- [ ] **[Lambda](providers/lambda/)** 🟡 `elct9620/lambdalabs` · 🎓 No free tier; research grants up to $5K
- [ ] **[Modal](providers/modal/)** ⚪ · 🔁 $30/month compute credit on the Starter plan (CPU and GPU, serverless containers); no card required
- [ ] **[Nebius AI Cloud](providers/nebius/)** 🟡 `nebius/nebius` · 🎓 No free tier; Nebius AI Lift up to $150K credits for NVIDIA Inception members
- [ ] **[Paperspace (DigitalOcean)](providers/paperspace/)** 🟠 `paperspace/paperspace` · ♾️ Gradient free plan: public projects, 5 GB storage, basic instances
- [ ] **[RunPod](providers/runpod/)** 🟡 `runpod/runpod` · 🎓 No self-serve free credit; startup tier up to $1,000 by application; per-second GPU billing
- [ ] **[Vast.ai](providers/vast-ai/)** ⚪ · 🎓 GPU marketplace, no free tier; startup program up to $2,500 (launched Feb 2026)
- [ ] **[Verda (formerly DataCrunch)](providers/verda/)** 🟡 `verda-cloud/verda` · 💲 No free tier found during research; renamed from DataCrunch in Nov 2025

### Containers & PaaS (1/12)

Run a container without managing a VM. Free tiers usually sleep when idle.

- [ ] **[Appwrite Cloud](providers/appwrite/)** 🟢 `appwrite/appwrite` · ♾️ Unlimited projects with no pausing; per project: 1 database, 3 buckets, 5 functions
- [ ] **[Back4App Containers](providers/back4app/)** ⚪ · ♾️ 1 container, 256 MB RAM, 100 GB transfer
- [ ] **[Clever Cloud](providers/clever-cloud/)** 🟡 `CleverCloud/clevercloud` · ⏳ EUR 20 credit at sign-up; DEV plan with free MySQL and PostgreSQL
- [ ] **[Google Cloud Run](providers/cloud-run/)** 🟢 `hashicorp/google` · ♾️ With request-based billing, per billing account and month: 2M requests, 180,000 vCPU-seconds and 360,000 GB-seconds; scales to zero between requests
- [ ] **[Koyeb](providers/koyeb/)** 🟢 `koyeb/koyeb` · ♾️ 1 free web service per organisation (512 MB, 0.1 vCPU, Frankfurt or Washington), scales to zero after 1 h idle; free Postgres with 5 compute-hours/month
- [ ] **[Leapcell](providers/leapcell/)** ⚪ · ♾️ Hobby plan: 20 projects, 100k serverless invocations/month, 3 GB-hours compute, 2 GB transfer
- [x] **[Northflank](providers/northflank/)** ⚪ · ♾️ Sandbox: 2 services, 2 jobs and 1 database, always on with no sleeping, plans up to nf-compute-20 (0.2 vCPU, 512 MB) and up to $20/month of resources; no card · **recommended**
- [ ] **[Railway](providers/railway/)** 🟡 `terraform-community-providers/railway` · 🔁 $5 trial credit for 30 days, then the Free plan: $1 of usage credit a month, up to 1 vCPU and 0.5 GB RAM per service, 0.5 GB volume
- [ ] **[Render](providers/render/)** 🟢 `render-oss/render` · ♾️ Free web services: 750 instance-hours/month, 512 MB / 0.1 CPU, spin down after 15 min idle; free Postgres expires after 30 days; 5 GB/month bandwidth
- [ ] **[Scaleway](providers/scaleway/)** 🟢 `scaleway/scaleway` · ♾️ Serverless Containers: 400,000 GB-s of memory and 200,000 vCPU-s per account and month, enough for one 128 MB container all month or bigger ones that scale to zero; no free VMs; Startup Program for EU companies (up to EUR 36K)
- [ ] **[SnapDeploy](providers/snapdeploy/)** ⚪ · ♾️ 4 containers, 100 container-hours/month, 512 MB / 0.25 vCPU; sleeps after 15 min idle
- [ ] **[Zeabur](providers/zeabur/)** ⚪ · ♾️ $0 plan with auto-sleep

### Static, edge & serverless (1/6)

Static sites, edge functions and CDN in front of the hosts.

- [ ] **[bunny.net](providers/bunny-net/)** 🟡 `BunnyWay/bunnynet` · ⏳ 14-day trial with $20 credit (no card), plus $30 when billing details are added; then pay-as-you-go CDN from $0.01/GB in Europe and North America
- [x] **[Cloudflare](providers/cloudflare/)** 🟢 `cloudflare/cloudflare` · ♾️ DNS for unlimited domains, CDN/SSL/WAF basics, Tunnel, Zero Trust (50 users), Workers 100k requests/day, Pages (unlimited sites and bandwidth), R2 10 GB with no egress fees, D1 5 GB, KV, Queues
- [ ] **[Deno Deploy](providers/deno-deploy/)** 🟠 `denoland/deno` · ♾️ 100k requests/day and 100 GiB transfer/month
- [ ] **[Fastly](providers/fastly/)** 🟢 `fastly/fastly` · ♾️ Monthly: CDN 100 GB per region + 1M requests, Compute 10M requests + 100M vCPU-ms, 5 GB object storage, 1 GB KV store, 5 TLS domains
- [ ] **[Netlify](providers/netlify/)** 🟢 `netlify/netlify` · ♾️ 300 credits/month (hard limit; credit-based since Sep 2025)
- [ ] **[Vercel](providers/vercel/)** 🟢 `vercel/vercel` · ♾️ Hobby (non-commercial only): 100 GB transfer, 1M edge requests, 1M function invocations; only the 3 latest production deployments kept

### Managed databases (0/23)

Keep state off free VMs, which can be reclaimed: managed Postgres, MySQL, Redis, document and analytics databases.

- [ ] **[Aiven](providers/aiven/)** 🟢 `aiven/aiven` · ♾️ Free PostgreSQL, MySQL and Valkey: single node, 1 CPU, 1 GB RAM, 1 GB storage (PostgreSQL/MySQL)
- [ ] **[ClickHouse Cloud](providers/clickhouse/)** 🟢 `ClickHouse/clickhouse` · ⏳ Trial credit for new accounts
- [ ] **[CockroachDB Cloud](providers/cockroachdb/)** 🟢 `cockroachdb/cockroach` · ♾️ 50M request units + 10 GiB storage per month
- [ ] **[Couchbase Capella](providers/couchbase-capella/)** 🟢 `couchbasecloud/couchbase-capella` · ♾️ Forever-free 1-node cluster with 8 GB storage
- [ ] **[CrateDB Cloud](providers/crate/)** ⚪ · ♾️ 1 node with 2 CPUs, 2 GiB memory, 8 GiB storage; no payment method needed
- [ ] **[DataStax Astra DB](providers/datastax-astra/)** 🟢 `datastax/astra` · ♾️ Free serverless tier
- [ ] **[Elastic Cloud](providers/elastic-cloud/)** 🟢 `elastic/ec` · ⏳ Free trial for new accounts
- [ ] **[InfluxDB Cloud](providers/influxdb/)** ⚪ · ♾️ Writes up to 3 MB/5 min, reads 30 MB/5 min, 10,000 series cardinality
- [ ] **[MongoDB Atlas](providers/mongodb-atlas/)** 🟢 `mongodb/mongodbatlas` · ♾️ M0 cluster with 512 MB storage
- [ ] **[MotherDuck](providers/motherduck/)** 🟡 `motherduckdb/motherduck` · ♾️ Lite plan: 10 GB storage, 10 Pulse compute-hours/month, 3 users and 2 service accounts; serverless DuckDB for analytics
- [ ] **[Neo4j AuraDB](providers/neo4j-aura/)** 🟡 `neo4j-labs/neo4jaura` · ♾️ AuraDB Free: 200k nodes, 400k relationships, 1 GB storage; managed graph database
- [ ] **[Neon](providers/neon/)** 🟡 `kislerdm/neon` · ♾️ 0.5 GB storage per project, up to 100 projects, 100 CU-hours/project/month, scales to zero after 5 min
- [ ] **[Nile](providers/nile/)** ⚪ · ♾️ Unlimited databases, 1 GB storage total, 50M query tokens
- [ ] **[Prisma Postgres](providers/prisma-postgres/)** ⚪ · ♾️ 1.01 GB storage, 200k operations/month, 50 databases; no card
- [ ] **[Redis Cloud](providers/redis-cloud/)** 🟢 `RedisLabs/rediscloud` · ♾️ Free 30 MB database
- [ ] **[SingleStore Helios](providers/singlestore/)** 🟢 `singlestore-labs/singlestoredb` · ♾️ Free shared tier
- [ ] **[Supabase](providers/supabase/)** 🟡 `supabase/supabase` · ♾️ 2 active projects, 500 MB database, 1 GB file storage; free projects pause after a week of inactivity
- [ ] **[TiDB Cloud](providers/tidb-cloud/)** 🟢 `tidbcloud/tidbcloud` · ♾️ 5 free Starter clusters per organisation, each with 5 GiB row storage, 5 GiB columnar storage and 50M request units/month; MySQL-compatible
- [ ] **[Tiger Data (Timescale)](providers/timescale/)** 🟢 `timescale/timescale` · ⏳ Free trial for new accounts
- [ ] **[Tinybird](providers/tinybird/)** ⚪ · ♾️ 10 GB storage + 1,000 API requests/day
- [ ] **[Turso](providers/turso/)** 🟠 `celest-dev/turso` · ♾️ 9 GB total storage, up to 500 databases, 1B row reads/month
- [ ] **[Upstash](providers/upstash/)** 🟡 `upstash/upstash` · ♾️ Redis: 256 MB, 500K commands/month; QStash messaging
- [ ] **[YugabyteDB Aeon](providers/yugabyte/)** 🟡 `yugabyte/ybm` · ♾️ Free sandbox cluster

### Object storage (1/2)

S3-compatible buckets for backups and assets. Cloudflare R2 is listed under Cloudflare.

- [x] **[Backblaze B2](providers/backblaze-b2/)** 🟢 `Backblaze/b2` · ♾️ 10 GB S3-compatible storage, always free; downloads free up to 3x the average stored · **recommended**
- [ ] **[Filebase](providers/filebase/)** ⚪ · ♾️ 5 GB S3-compatible storage

### Networking & tunnels (0/7)

Private mesh networks and tunnels that join hosts across clouds into one network.

- [ ] **[Defined Networking (Managed Nebula)](providers/defined-networking/)** 🟡 `sendsmaily/definednet` · ♾️ Managed Nebula mesh: up to 100 hosts, managed lighthouse, SSO and 2 routes; then $1/host/month
- [ ] **[Firezone](providers/firezone/)** 🟡 `firezone/firezone` · ♾️ Starter: up to 6 users, 1 admin, 10 service accounts, 10 sites, unlimited clients; WireGuard-based zero-trust access
- [ ] **[NetBird](providers/netbird/)** 🟡 `netbirdio/netbird` · ♾️ Free cloud plan for small teams
- [ ] **[ngrok](providers/ngrok/)** 🟢 `ngrok/ngrok` · ♾️ Free plan with limited endpoints and bandwidth
- [ ] **[Tailscale](providers/tailscale/)** 🟡 `tailscale/tailscale` · ♾️ Personal plan: 3 users, 100 devices
- [ ] **[Twingate](providers/twingate/)** 🟡 `Twingate/twingate` · ♾️ Free Starter plan for small teams
- [ ] **[ZeroTier](providers/zerotier/)** 🟢 `zerotier/zerotier` · ♾️ Unlimited networks, 25 clients

### Free domains (3/3)

Free names to use instead of a paid domain. Each can be delegated to Cloudflare, so the cloudflare stack serves your apps on it. `freelunch domain suggest` checks which names are still free.

- [x] **[DigitalPlat FreeDomain](providers/digitalplat/)** ⚪ · ♾️ One free name per account under dpdns.org, qzz.io, us.kg or xx.kg, ready in minutes; the dashboard shows which suffixes take new names · **recommended**
- [x] **[EU.org](providers/eu-org/)** ⚪ · ♾️ Free names under eu.org or a country subdomain such as de.eu.org, with no expiry; requests are checked by hand and can take months
- [x] **[pp.ua](providers/pp-ua/)** ⚪ · ♾️ Free names under pp.ua, renewed every year for free with a phone check by SMS or Telegram

### DNS (0/5)

Free DNS hosting with an API. Cloudflare and Hetzner DNS are covered by their own providers.

- [ ] **[ClouDNS](providers/cloudns/)** 🟡 `ClouDNS/cloudns` · ♾️ 1 domain with 50 records
- [ ] **[deSEC](providers/desec/)** 🟡 `Valodim/desec` · ♾️ Free DNS hosting with API and DNSSEC
- [ ] **[Duck DNS](providers/duckdns/)** ⚪ · ♾️ Free dynamic DNS, up to 5 subdomains
- [ ] **[Gcore](providers/gcore/)** 🟢 `G-Core/gcore` · ♾️ Free managed DNS: unlimited zones and queries, anycast across 210+ PoPs, 1 dynamic (GeoDNS/failover) record set per zone; CDN and edge cloud are pay-as-you-go
- [ ] **[Namecheap FreeDNS](providers/namecheap/)** 🟡 `namecheap/namecheap` · ♾️ Free DNS with no domain limit

### Observability (0/14)

Metrics, logs, uptime and alerting for every host and service.

- [ ] **[Axiom](providers/axiom/)** 🟡 `axiomhq/axiom` · ♾️ 0.5 TB logs with 30-day retention
- [ ] **[Better Stack](providers/better-stack/)** 🟢 `BetterStackHQ/better-uptime` · ♾️ 10 monitors with 3-min checks, status page; logs via the BetterStackHQ/logtail provider
- [ ] **[Checkly](providers/checkly/)** 🟢 `checkly/checkly` · ♾️ 1 user, 10k API/network + 1.5k browser check runs/month
- [ ] **[Datadog](providers/datadog/)** 🟢 `DataDog/datadog` · ♾️ Free for up to 5 hosts (short retention)
- [ ] **[Grafana Cloud](providers/grafana-cloud/)** 🟢 `grafana/grafana` · ♾️ 3 users, 10 dashboards, 100 alerts, 10k metric series, 50 GB logs, 14-day retention
- [ ] **[Healthchecks.io](providers/healthchecks-io/)** 🟡 `kristofferahl/healthchecksio` · ♾️ 20 cron/heartbeat checks
- [ ] **[Honeycomb](providers/honeycomb/)** 🟢 `honeycombio/honeycombio` · ♾️ Free plan with a monthly event allowance
- [ ] **[Netdata Cloud](providers/netdata/)** 🟡 `netdata/netdata` · ♾️ Community plan: 5 active connected nodes, 1 custom dashboard per room; personal, non-commercial use only
- [ ] **[New Relic](providers/new-relic/)** 🟢 `newrelic/newrelic` · ♾️ 100 GB/month data ingest, 1 full platform user
- [ ] **[PagerDuty](providers/pagerduty/)** 🟢 `PagerDuty/pagerduty` · ♾️ Free plan for small teams
- [ ] **[Sentry](providers/sentry/)** 🟡 `jianyuan/sentry` · ♾️ 5k errors/month, 1 user
- [ ] **[Site24x7](providers/site24x7/)** 🟢 `site24x7/site24x7` · ♾️ Free forever plan: uptime monitoring for up to 50 resources with email alerts; 30-day full trial without a card
- [ ] **[StatusCake](providers/statuscake/)** 🟠 `StatusCakeDev/statuscake` · ♾️ 10 uptime monitors at 5-min intervals, 1 page speed, 1 domain and 1 SSL monitor
- [ ] **[UptimeRobot](providers/uptimerobot/)** 🟠 `louy/uptimerobot` · ♾️ 50 monitors with 5-min interval

### Secrets (0/5)

Secret stores that keep credentials out of cloud-init and state.

- [ ] **[Akeyless](providers/akeyless/)** 🟡 `akeyless-community/akeyless` · ♾️ 5 clients, 500 static secrets, 5 dynamic and 5 rotated secrets, 1 gateway
- [ ] **[Bitwarden Secrets Manager](providers/bitwarden-secrets/)** 🟡 `bitwarden/bitwarden-secrets` · ♾️ Free plan for individuals
- [ ] **[Doppler](providers/doppler/)** 🟡 `DopplerHQ/doppler` · ♾️ Free for 5 users
- [ ] **[Infisical](providers/infisical/)** 🟡 `Infisical/infisical` · ♾️ Free for up to 5 developers; open source and self-hostable
- [ ] **[Phase](providers/phase/)** 🟠 `phasehq/phase` · ♾️ 5 users or service accounts, 3 apps, 3 environments; open source and self-hostable

### Messaging & queues (0/5)

Managed brokers and queues. Upstash QStash is listed under Upstash.

- [ ] **[Ably](providers/ably/)** 🟢 `ably/ably` · ♾️ 6M messages/month, 200 concurrent connections, 200 concurrent channels, 500 messages/s; realtime pub/sub over WebSockets
- [ ] **[CloudAMQP](providers/cloudamqp/)** 🟡 `cloudamqp/cloudamqp` · ♾️ Little Lemur RabbitMQ: 1M messages/month, 20 connections, 100 queues
- [ ] **[Confluent Cloud](providers/confluent/)** 🟢 `confluentinc/confluent` · ⏳ Trial credit for new accounts
- [ ] **[Redpanda Cloud](providers/redpanda/)** 🟡 `redpanda-data/redpanda` · ⏳ Serverless: $100 credit for the first 30 days, no card; then pay-as-you-go; Kafka API compatible
- [ ] **[Synadia Cloud (NATS)](providers/synadia-cloud/)** 🟡 `nats-io/jetstream` · ♾️ Personal plan: 10 connections, 100 subscriptions, 10 GB data transfer and 5 GB JetStream storage, 2 accounts, 1 MB max message

### IaC state, CI & registries (0/11)

Remote state, pipelines and container registries for running freelunch itself.

- [ ] **[Azure DevOps](providers/azure-devops/)** 🟢 `microsoft/azuredevops` · ♾️ 5 Basic users; 1 Microsoft-hosted parallel job with 1,800 minutes/month; 1 self-hosted parallel job with unlimited minutes
- [ ] **[Bitbucket Cloud](providers/bitbucket/)** 🟡 `DrFaust92/bitbucket` · ♾️ Free for 5 users: unlimited private repos, 50 Pipelines build minutes/month, 1 GB LFS, 1 GB storage per repository
- [ ] **[Buildkite](providers/buildkite/)** 🟢 `buildkite/buildkite` · ♾️ Free plan: 5 users, 10 concurrent jobs, 2,000 hosted Linux vCPU-minutes/month, 30-day build retention, 250k test executions/month
- [ ] **[CircleCI](providers/circleci/)** 🟡 `CircleCI-Public/circleci` · ♾️ 30,000 credits/month (about 6,000 small Docker minutes), 5 active users, 30 concurrent jobs, 2 GB storage
- [ ] **[Codeberg](providers/codeberg/)** 🟡 `svalabs/forgejo` · ♾️ Free Forgejo hosting for free/libre-licensed projects: Git repos, Forgejo Actions runners, package and container registry
- [ ] **[Docker Hub](providers/docker-hub/)** 🟡 `docker/docker` · ♾️ 1 private repository, unlimited public repositories
- [ ] **[GitHub](providers/github/)** 🟢 `integrations/github` · ♾️ Pages (1 GB site, 100 GB/month soft bandwidth, public repos on Free), Actions minutes, GHCR for public images
- [ ] **[GitLab](providers/gitlab/)** 🟢 `gitlabhq/gitlab` · ♾️ Unlimited repos with up to 5 collaborators; CI/CD minutes, Pages, Container Registry
- [ ] **[HCP Terraform](providers/hcp-terraform/)** 🟢 `hashicorp/tfe` · ♾️ Free tier capped at 500 managed resources (legacy free plan ended 2026-03-31)
- [ ] **[Scalr](providers/scalr/)** 🟡 `scalr/scalr` · ♾️ All features; 50 runs/month free
- [ ] **[Spacelift](providers/spacelift/)** 🟡 `spacelift-io/spacelift` · ♾️ Free plan: public worker pools up to 200 minutes/month

### Excluded

Catalogued so they don't get re-proposed. Details are in each folder.

- ~~[ElephantSQL](providers/elephantsql/)~~: Shut down on 2025-01-27 (previously a free 20 MB Postgres)
- ~~[Equinix Metal](providers/equinix-metal/)~~: Bare-metal service sunset on 2026-06-30; resources removed on 2026-07-01
- ~~[Fauna](providers/fauna/)~~: Shut down on 2025-05-30; accounts and data deleted
- ~~[Fly.io](providers/fly-io/)~~: No free allowance since 2024-10-07; trial of 2 machine-hours or 7 days
- ~~[Freenom](providers/freenom/)~~: Stopped registrations in March 2023 and left the domain business in February 2024 (previously free .tk, .ml, .ga, .cf and .gq names)
- ~~[Glitch](providers/glitch/)~~: Project hosting ended on 2025-07-08
- ~~[HCP Vault Secrets](providers/hcp-vault-secrets/)~~: End of sale 2025-06-30, end of life 2026-07-01; applications deleted
- ~~[Heroku](providers/heroku/)~~: No free tier since 2022-11-28; Eco dynos from $5/month
- ~~[is-a.dev](providers/is-a-dev/)~~: Free name.is-a.dev subdomains, but no NS delegation to DNS hosts such as Cloudflare, so they can't be a zone for the cloudflare stack
- ~~[OpenObserve Cloud](providers/openobserve/)~~: Cloud free tier discontinued in June 2025; 14-day trial, then pay-as-you-go
- ~~[Opsgenie](providers/opsgenie/)~~: End of sale 2025-06-04 (no new sign-ups); shut off on 2027-04-05
- ~~[PlanetScale](providers/planetscale/)~~: No free tier since the Hobby plan was removed in 2024
- ~~[Storj](providers/storj/)~~: Free tier replaced by a 30-day trial on 2025-07-01; $5/month minimum after the trial
- ~~[Tebi](providers/tebi/)~~: Shut down on 2026-03-31 (previously 25 GB S3-compatible storage free)
<!-- END PROVIDER CHECKLIST -->

## Adding a provider

Start from [`providers/_template`](providers/_template/) and follow
[docs/adding-a-provider.md](docs/adding-a-provider.md). In short: fill in `provider.yaml`,
build modules that stay inside the free tier by default, expose the host contract (for
compute), add offline tests with `mock_provider`, then run `bin/freelunch catalog`.
[CONTRIBUTING.md](CONTRIBUTING.md) has the rest.

## License

[Apache-2.0](LICENSE)

## Disclaimer

You are responsible for what runs in your accounts. Set budget alerts at the lowest
threshold each provider allows, especially on Pay-As-You-Go accounts, where anything
above the free caps is billed.
