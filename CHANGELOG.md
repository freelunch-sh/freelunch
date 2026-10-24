# Changelog

All notable changes to freelunch. Versions follow [semantic versioning](https://semver.org/):
a minor release per usable feature, a major release only for breaking changes to the host
contract, the CLI or the project layout.

## [Unreleased]

The first release, planned as 1.0.0: deploy your project's container from its own repository.

### Added

- **Project mode.** `freelunch init` creates a `.freelunch/` folder in any repository, with a
  `terraform.tfvars.example` per stack, `apps.tfvars`, `.env.example` and a `.gitignore`.
  Each example sets `name_prefix` to the project's name (`--name`, or the folder's), so VMs,
  networks, tunnels and service tokens are named after the project and two projects on the
  same accounts don't clash.
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
  OCI CLI; stacks without a tfvars; the OCI profile, a session's expiry, the API key and
  the home region; the key deploy signs in with against `ssh_public_keys`; registry tokens
  and whether each image has a build for its host; the Cloudflare token
  (`/user/tokens/verify`), whether it reaches the zone's DNS records, the account's tunnels
  and Access, and whether the zone is active. It only reads.
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
  API, with its URLs; when each service token expires; and capacity waits. `deploy`,
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
  session's 24 hours are up. `FREELUNCH_CAPACITY_INTERVAL` and `FREELUNCH_CAPACITY_TIMEOUT`
  tune it.
- **Unattended capacity waits.** `freelunch plan <stack> --out <file>` saves a plan to
  review, and `apply --plan <file>` applies exactly that plan without a prompt. With
  `--wait-for-capacity`, a retry after a reviewed plan is applied only when it changes
  nothing the reviewed plan doesn't, so CI, a cron job or an agent can do the waiting. Each
  retry tries the next availability domain that offers the shape
  (`availability_domain_offset`), and a created instance never changes domain
  (`availability_domain` is in `ignore_changes`). `--detach` waits in the background with
  its output in `.freelunch/<stack>/wait.log`, `freelunch status` shows the attempts and
  the next try, and a desktop notification, plus `FREELUNCH_NOTIFY` (ntfy, Discord or
  Slack), says when the wait ends.
- **OCI sign-in check.** Every plan, apply and destroy of the oci stack refreshes a session
  token first (without the OCI CLI, it reads the expiry from the token), and an expired
  session stops the run with the command to sign in again, instead of a half plan between
  `401-NotAuthenticated` errors. When `~/.oci/config` has no API key, `freelunch init`
  points to `oci setup bootstrap`, which creates one that doesn't expire.
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
- **Container platforms**, a new `platform` layer for providers that run an app's image
  without a VM, through their API. **Northflank** is the first, and the recommended one in
  Containers & PaaS: its free Sandbox runs two always-on services without a card.
  `freelunch apply northflank` checks the plan against the free limits and creates a project
  named after the freelunch project. `freelunch deploy` turns each app's Compose service into
  a Northflank service (the image pinned to the digest its tag points to, command,
  environment with the app's env file, private ports, the healthcheck as a readiness check),
  saves the registry logins for that project only, runs `cloudflared` as the second service
  and waits until each one runs. `status` and `doctor` ask Northflank, and
  `destroy northflank` deletes the services, the logins and the project. freelunch never
  takes over a project it didn't make. Moving an app from a VM is changing its target in
  `apps.tfvars` and its route, which names the app on a platform (`app = "api"`); the
  walkthrough's new "Switch to another provider" shows it for Northflank and GCP.
- The [platform contract](docs/architecture.md#platform-contract): `hybrid/` aggregates
  `platforms` next to `hosts`, the cloudflare stack routes to `<app>:<port>` on a platform,
  and `deploy/` reads each platform app's Compose file and stops on what the platform can't
  do: volumes, a build without an image, Compose variables in the image, more services than
  the free plan has, or a route to an app or port that isn't there.

### Changed

- The CLI loads credentials from `.freelunch/.env` (or `.env` in the checkout); variables
  already set in the shell win. A value can name a secret instead of holding it:
  `op://<vault>/<item>/<field>` from 1Password through the op CLI, or `keychain:<name>`
  from the macOS keychain. Only commands that use credentials read them (plan, apply,
  destroy, deploy, status, domain add and status; doctor reports on them), so `list` or
  `init` never prompt.
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
