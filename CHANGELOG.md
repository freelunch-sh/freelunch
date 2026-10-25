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
  Each example sets `name_prefix` to the project's name (`--name`, the one the project's
  other stacks have, or the folder's), so VMs,
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
  prints the nameservers to set at the provider. It puts the zone in the account the token
  lists (with Account → Account Settings → Read), the account of a zone the token can read,
  or `CLOUDFLARE_ACCOUNT_ID`, and `doctor` warns when it can't tell which. `freelunch domain
  status <name>` says whether the nameservers are set and the zone is active, asks
  Cloudflare to check again once they are, and exits with an error until the name is ready.
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
- **Container platforms**, a new `platform` layer for providers that run an app's image
  without a VM, through their API. **Northflank** is the first, and the recommended one in
  Containers & PaaS: its free Sandbox runs two always-on services without a card.
  `freelunch apply northflank` checks the plan against the free limits and creates a project
  named after the freelunch project; `doctor`, `plan --out` and `apply` say when another
  project already takes the Sandbox's one. `freelunch deploy` turns each app's Compose service into
  a Northflank service (the image pinned to the digest its tag points to, command,
  environment with the app's env file, private ports, the healthcheck as a readiness check),
  saves the registry logins for that project only, runs `cloudflared` as the second service
  and waits until each one runs. `status` and `doctor` ask Northflank, and
  `destroy northflank` deletes the services, the logins and the project. freelunch never
  takes over a project it didn't make. deploy and `--dry-run` check every service against
  the fields Northflank requires before anything is sent. A request Northflank turns down shows its details
  (the field and why), with the request's secrets left out. Moving an app from a VM is changing its target in
  `apps.tfvars` and its route, which names the app on a platform (`app = "api"`); the
  walkthrough's new "Switch to another provider" shows it for Northflank and GCP.
- The [platform contract](docs/architecture.md#platform-contract): `hybrid/` aggregates
  `platforms` next to `hosts`, the cloudflare stack routes to `<app>:<port>` on a platform,
  and `deploy/` reads each platform app's Compose file and stops on what the platform can't
  do: volumes, a build without an image, Compose variables in the image, more services than
  the free plan has, or a route to an app or port that isn't there.
- Catalog: Google Cloud Run and Scaleway Serverless Containers with their free tiers, and
  Railway's Free plan checked again, each with what stops it for now. The container
  platforms (Koyeb, Render, Railway and the rest) moved to the `platform` layer. The GCP
  page notes that an external IPv6 address isn't billed, while ghcr.io has no IPv6 yet, and
  that Standard Tier's 200 GiB of free egress is per account, not per region.
- **State store.** A project can keep a copy of every stack's state where CI and its other
  machines reach it: `.freelunch/state.<backend>.tfbackend`, the settings of any
  tofu/terraform backend with `{stack}` in the key. `freelunch state init oci` makes a
  private, versioned bucket in the tenancy's Object Storage (20 GB Always Free) and a
  Customer Secret Key for its S3 API; `r2`, `b2` and `gitlab` write the settings to fill in.
  Commands that read state take the store's copy when it is newer, and apply, destroy and
  each attempt of a wait copy theirs back. A copy never overwrites a newer one, and when two
  machines changed a stack at once, a command that works on that stack stops until
  `freelunch state push --force` or `pull --force` keeps one; the others go on with the copy
  here. The same lineage and serial count as in step, whichever tofu/terraform version wrote
  them. While the store turns down a key `state init oci` made minutes ago (a new Customer
  Secret Key works on some servers before the others), state runs try again for up to 10
  minutes and say "key not active yet" instead of the raw S3 error. The copy is encrypted with OpenTofu's state encryption and
  `FREELUNCH_STATE_PASSPHRASE`, which `state init` makes. `freelunch state` shows where each
  stack stands, and `doctor` checks the store. The store's credentials
  (`FREELUNCH_STATE_<NAME>`) reach its runs only.
- **Run freelunch from CI** ([docs/ci.md](docs/ci.md)). A GitHub Action (`action.yml`,
  `uses: freelunch-sh/freelunch@<tag>`, or `./freelunch` for a submodule) sets up tofu or
  terraform and runs a command. `freelunch ci init` writes two workflows: one that waits for
  capacity on a schedule, and one that deploys after each new image of `main` and runs any
  command on demand (`ci init gitlab` writes a GitLab pipeline). `freelunch ci secrets` puts
  what git doesn't have into one secret, `FREELUNCH_BUNDLE`: tfvars, `.env` with the
  secrets from 1Password or the keychain read, app env files, `known_hosts`, the OCI profile
  and its API key, and the deploy key; `ci restore` writes them back in the job, and masks
  the env files' values in the log.
- **A wait for capacity in GitHub Actions**, for a wait that outlasts a laptop:
  `freelunch ci wait <stack> --plan <file>` approves what a plan reviewed here changes,
  puts the approval in the bundle and starts the wait workflow. Each run makes one attempt
  (`ci resume`), in the next availability domain, and applies only what the approval
  lists, with the tfvars it was made with; the workflow turns itself off once the host
  exists, and after three failed runs in a row; `ci wait <stack>` without `--plan` turns it
  on again. Meanwhile `status` shows the wait, and `apply` and `destroy` of that stack stop
  here; `ci wait --cancel` ends it. `FREELUNCH_WAIT_ATTEMPT` lets any scheduler go on with
  a wait from run to run, and such a run exits with 75 where `FREELUNCH_CAPACITY_TIMEOUT`
  pauses it.

### Changed

- `apply` and `destroy` without a terminal, where tofu/terraform can't ask for a yes, say
  what to use instead: a saved plan (`plan --out`, then `apply --plan`), or
  `FREELUNCH_AUTO_APPROVE=1` for `destroy`.
- `apply --wait-for-capacity` also retries what leaves nothing half done: a 401 for clock
  skew, from a request signed before the machine slept, and a network failure while
  planning, or on a read while applying. An attempt that made part of a reviewed plan no
  longer ends the wait, or one started again with that plan: it plans again and applies
  only what the reviewed plan does. A wait whose machine slept through a pause says so, and
  `--detach` says that a long wait needs a machine that stays on.
- In CI, `deploy` talks only to hosts whose key `known_hosts` has (`FREELUNCH_SSH_STRICT=1`).
- `freelunch init` adds `*/approved.json` to `.freelunch/.gitignore`.

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
- `freelunch init` routes the cloudflare example to the project's first host or platform
  (`gcp-main`, `northflank-main`) instead of always `oci-main`, and on a platform makes the
  app's name one the platform takes.
- `freelunch destroy` of glue or service stacks alone no longer exits with status 1 after a
  successful destroy, and `freelunch status` no longer stops when the cloudflare stack has
  state but no `terraform.tfvars`.

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
