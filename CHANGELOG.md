# Changelog

All notable changes to freelunch. Versions follow [semantic versioning](https://semver.org/):
a minor release per usable feature, a major release only for breaking changes to the host
contract, the CLI or the project layout.

## [Unreleased]

The first release, planned as 1.0.0: deploy your project's container from its own repository.

### Added

- **Project mode.** `freelunch init` creates a `.freelunch/` folder in any repository, with a
  `terraform.tfvars.example` per stack, `apps.tfvars`, `.env.example` and a `.gitignore`.
  Host stacks get their `project.tfvars.example`, with only SSH open and no apps in
  cloud-init, since the tunnel serves the apps and `deploy` runs them. In that folder's
  tree every command reads tfvars and writes state, `inventory.json` and provider plugins
  in the project. Inside the freelunch checkout nothing changes.
- **`freelunch deploy`.** Copies each app's Compose file and env file to its host over SSH,
  logs in to private registries, runs `docker compose up --wait` and fails when a container
  stays unhealthy, then starts `cloudflared` and prunes unused images. Targets a host, a
  provider or everything; `--dry-run` prints the remote script with secrets left out.
- **Cloudflare glue stack** (`providers/cloudflare`): a remotely managed tunnel per host,
  proxied DNS records, optional Access email login per hostname, zone looked up by name.
  The tunnel token reaches the host through `deploy`, never through cloud-init.
- **Access service tokens** for machine clients: `access = { service_tokens = ["backend"] }`
  on a route puts a Service Auth policy in front of it, so Cloudflare answers 401 to
  requests without the token's headers and they never reach the host.
- `freelunch output <stack> [name]` prints a stack's outputs from its state, e.g.
  `output cloudflare -json service_tokens` or `output hybrid -raw ssh_config`.
- **`freelunch apply --wait-for-capacity`** keeps retrying a host stack while OCI is out of
  capacity, with the project's tfvars, state and plugins like any other run. You approve
  the first attempt; each retry plans again and applies that plan only if it destroys
  nothing. Rate limits double the wait, up to 30 minutes. With a session token it runs
  `oci session refresh` before each attempt and stops with the sign-in command once the
  session's 24 hours are up. `FREELUNCH_CAPACITY_INTERVAL` and `FREELUNCH_CAPACITY_TIMEOUT`
  tune it.
- **Free domains.** A new catalog category with DigitalPlat FreeDomain (recommended), EU.org
  and pp.ua, whose free names (`myapp.dpdns.org`, `myapp.eu.org`, `myapp.pp.ua`) work as the
  cloudflare stack's zone. Freenom and is-a.dev are listed under Excluded with the reason.
  `freelunch domain suggest <name...>` looks names like yours up at each of them, the
  recommended one first, and offers similar names where yours is taken.
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
  already set in the shell win.
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
  `docs/deploy-a-container.md` shows how to pin the keys from the OCI console beforehand.
- `cloudflared` is pinned by digest and runs without capabilities, privilege escalation or
  a writable filesystem.
- The host stacks' project examples explain who can reach SSH and how to close it with
  Tailscale.
