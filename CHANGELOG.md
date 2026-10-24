# Changelog

All notable changes to freelunch. Versions follow [semantic versioning](https://semver.org/):
a minor release per usable feature, a major release only for breaking changes to the host
contract, the CLI or the project layout.

## [Unreleased]

The first release, planned as 1.0.0: deploy your project's container from its own repository.

### Upgrading a project made before this release

For a project set up with freelunch from `main` before 1.0.0:

- Run `freelunch init` in it again. It keeps every file and adds the lines
  `.freelunch/.gitignore` lacks (`*/wait.log`, `*/wait.state` and `*.tfplan` came later).
- `name_prefix` came later too. Without it, a stack's resources keep the name `freelunch`;
  `init` only writes it into examples it creates, so set it in each stack's
  `terraform.tfvars` yourself. The OCI network and hosts are renamed in place. Review the
  other stacks' plans with `freelunch plan <stack> --out <file>`, which says what a plan
  replaces: a replaced tunnel gets a new token, which the next `freelunch deploy` takes to
  its host.
- `init` doesn't rewrite examples it kept. Compare yours with the stack's
  `project.tfvars.example` in freelunch for settings that came since.

### Added

- **Project mode.** `freelunch init` creates a `.freelunch/` folder in any repository, with a
  `terraform.tfvars.example` per stack, `apps.tfvars`, `.env.example` and a `.gitignore`.
  Each example sets `name_prefix` to the project's name (`--name`, or the folder's), so VMs,
  networks, tunnels and service tokens are named after the project and two projects on the
  same accounts don't clash. When it runs again, `init` keeps every file, adds the lines an older
  `.gitignore` lacks, and checks the compose files that the `apps.tfvars` it kept names.
  Host stacks get their `project.tfvars.example`, with only SSH open and no apps in
  cloud-init, since the tunnel serves the apps and `deploy` runs them. In that folder's
  tree every command reads tfvars and writes state, `inventory.json` and provider plugins
  in the project. Inside the freelunch checkout nothing changes.
- **`freelunch deploy`.** Copies each app's Compose file and env file to its host over SSH,
  logs in to private registries, runs `docker compose up --wait` and fails when a container
  stays unhealthy, then starts `cloudflared` and prunes unused images. Targets a host, a
  provider or everything; `--dry-run` prints the remote script with secrets left out.
  Before it connects, it asks each registry which platforms the images have, with the
  logins from `apps.tfvars`, and stops when one has no build for its host's architecture,
  is missing, or can't be read.
- **`freelunch doctor`** checks what plan, apply and deploy will need, before they spend
  time on it, and exits 1 when something is wrong: tofu or terraform, jq, curl, ssh and the
  OCI CLI; stacks without a tfvars; the OCI profile, when a session expires and ends, the
  API key (with OCI's status code and message when it is turned down) and the home region;
  how many VCNs and A1 cores the tenancy's limits leave for what the stack still creates,
  from OCI's limits API, which counts every project in the tenancy; the key deploy signs in
  with against `ssh_public_keys`; registry tokens and whether each image has a build for its
  host, also before the host exists (an OCI shape gives the architecture); the Cloudflare
  token (`/user/tokens/verify`), whether it reaches the zone's DNS records, the account's
  tunnels and Access, and whether the zone is active. It changes nothing, at the providers
  or in the project.
- `freelunch init --image-workflow` adds a GitHub Actions workflow that builds the project's
  image for its hosts (`linux/arm64` for OCI) and pushes it to `ghcr.io`.
- **Cloudflare glue stack** (`providers/cloudflare`): a remotely managed tunnel per host,
  proxied DNS records, optional Access email login per hostname, zone looked up by name.
  The tunnel token reaches the host through `deploy`, never through cloud-init.
- **Access service tokens** for machine clients: `access = { service_tokens = ["backend"] }`
  on a route puts a Service Auth policy in front of it, so Cloudflare answers 401 to
  requests without the token's headers and they never reach the host.
- **`freelunch status`** shows the project on one screen: hosts with their addresses,
  architecture and shape; the apps on each host and whether their containers run and are
  healthy (over SSH, only to hosts whose key is pinned, and apps that `apps.tfvars` lists
  but the host doesn't run yet); whether each tunnel is connected, from the Cloudflare
  API, with its URLs; when each service token expires; and capacity waits. Before the
  hosts exist it says what they wait for, and when the cloudflare stack is configured but
  not applied. `deploy`,
  `doctor` and `status` warn about a service token from 30 days before it expires.
- `freelunch output <stack> [name]` prints a stack's outputs from its state, e.g.
  `output cloudflare -json service_tokens` or `output hybrid -raw ssh_config`.
- `freelunch plan --show-user-data` prints the cloud-init of each host in the plan, decoded,
  with the Tailscale auth key and the content of `.env` files left out. The plan itself only
  shows `metadata = (sensitive value)`.
- `apply` ends with the address of each host it applied and the steps left before the apps
  run there: checking the host key, applying the cloudflare stack, `freelunch deploy`. A
  plain `apply` that fails for lack of OCI capacity prints the `--wait-for-capacity` command.
- **`freelunch apply --wait-for-capacity`** keeps retrying a host stack while OCI is out of
  capacity, with the project's tfvars, state and plugins like any other run. You approve
  the first attempt; each retry plans again and applies that plan only if it destroys
  nothing. Rate limits double the wait, up to 30 minutes. With a session token it runs
  `oci session refresh` before each attempt and stops with the sign-in command once the
  session ends, as many hours after signing in as the tenancy allows; it says when at the
  start, from the token (`sess_exp`). `FREELUNCH_CAPACITY_INTERVAL` and
  `FREELUNCH_CAPACITY_TIMEOUT` tune it.
- **Unattended capacity waits.** `freelunch plan <stack> --out <file>` saves a plan to
  review, and `apply --plan <file>` applies exactly that plan without a prompt. The file is
  readable only by you from the start, a plan that fails is not kept, and the CLI says what
  the plan replaces or destroys, and when the OCI tenancy has no VCN left for one it
  creates. With
  `--wait-for-capacity`, a retry after a reviewed plan is applied only when it changes
  nothing the reviewed plan doesn't, so CI, a cron job or an agent can do the waiting. Each
  retry tries the next availability domain that offers the shape
  (`availability_domain_offset`), and a created instance never changes domain
  (`availability_domain` is in `ignore_changes`). `--detach` waits in the background with
  its output in `.freelunch/<stack>/wait.log`, `freelunch status` shows the attempts, the
  next try and when the session ends, and a desktop notification, plus `FREELUNCH_NOTIFY`
  (ntfy, Discord or Slack), says when the wait ends. On a Mac, `caffeinate` keeps the Mac
  awake until then, since a session token can't be refreshed while it sleeps.
- **OCI sign-in check.** Every plan, apply and destroy of the oci stack refreshes a session
  token first (without the OCI CLI, it reads the expiry from the token), and an expired
  session stops the run with the command to sign in again, instead of a half plan between
  `401-NotAuthenticated` errors. A run that fails on OCI's errors says what to do about a
  401 (a new API key takes a few minutes to work everywhere) or a service limit. When
  `~/.oci/config` has no API key, `freelunch init` points to `oci setup bootstrap`, which
  creates one that doesn't expire.
- **Free domains.** A new catalog category with DigitalPlat FreeDomain (recommended), EU.org
  and pp.ua, whose free names (`myapp.dpdns.org`, `myapp.eu.org`, `myapp.pp.ua`) work as the
  cloudflare stack's zone. Freenom and is-a.dev are listed under Excluded with the reason.
  `freelunch domain suggest <name...>` looks names like yours up at each of them, the
  recommended one first, and offers similar names where yours is taken. A paid name you
  type comes first, with whether it is registered (RDAP, or DNS where an extension has no
  RDAP server). `freelunch domain add <name>` creates the zone on Cloudflare's free plan and
  prints the nameservers to set at the provider, and `freelunch domain status <name>` says
  whether they are set and the zone is active, asks Cloudflare to check again once they
  are, and exits with an error until the name is ready.
  `docs/free-domains.md` compares the providers and shows how to put a name on Cloudflare.
- `recommended: true` in `provider.yaml` marks the provider to start with in its category;
  the checklist shows it.
- `deploy/`, a read-only root module that resolves `apps.tfvars` against the inventory and
  the tunnels, with checks for unknown hosts and missing files.
- `hybrid/` takes `state_dir` to read host state from a project.
- Runner image with the code baked in, published to `ghcr.io/freelunch-sh/freelunch` for
  amd64 and arm64 on every tag.
- `examples/backend-app`, `docs/deploy-a-container.md`, `CONTRIBUTING.md`, Apache-2.0 license.
- CI: every suite on Terraform and the portable ones on OpenTofu, `fmt -check`, shellcheck,
  catalog drift check, and an image build.
- `freelunch test [folder...]` runs only the suites under the given folders.
- Offline tests: Cloudflare module and stack, `deploy/`, OCI network ingress, and
  `tests/cli.sh` for init, project state, deploy and domain suggest against a fake ssh,
  docker and DNS resolver.

### Changed

- The CLI loads credentials from `.freelunch/.env` (or `.env` in the checkout); variables
  already set in the shell win. A value can name a secret instead of holding it:
  `op://<vault>/<item>/<field>` from 1Password through the op CLI, or `keychain:<name>`
  from the macOS keychain. Only commands that use credentials read them (plan, apply,
  destroy, deploy, status, domain add and status; doctor reports on them), so `list` or
  `init` never prompt.
- An OCI network keeps the VCN DNS label it was created with, which OCI can't change, so a
  new `name_prefix` renames the VCN and its hosts in place instead of replacing them.
- `freelunch fmt` takes `-check`.
- `freelunch list` no longer reports a destroyed stack as deployed.

### Removed

- `providers/oci/scripts/retry-apply.sh`. It ran against the checkout instead of the
  project and stopped at the first expired session; `apply --wait-for-capacity` replaces it.

### Security

- Project mode keeps each stack's dependency lock file in `.freelunch/<stack>/`, so a
  project commits its provider versions and checksums. tofu/terraform only look for it
  next to the code, so the CLI copies it there for `init` and back.
- Hosts accept SSH keys only and no root login, rotate container logs, and reboot at 04:00
  (`reboot_time`) when a security update needs it.
- Tailscale comes from its signed apt repository instead of `curl | sh`, and the examples
  ask for a one-off auth key.
- `deploy` logs out of registries when it finishes, prints the digest each image tag
  resolved to, and shows the host key it trusts on first contact.
  `freelunch trust <host>` pins an OCI host's keys from its serial console beforehand: it
  captures the console through the OCI CLI, writes the keys for the address `deploy` uses,
  never replaces keys `known_hosts` has already, and stops when the host answers with
  another key.
- `cloudflared` is pinned by digest and runs without capabilities, privilege escalation or
  a writable filesystem.
- The host stacks' project examples explain who can reach SSH and how to close it with
  Tailscale.
