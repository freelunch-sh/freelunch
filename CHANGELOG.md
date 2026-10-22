# Changelog

All notable changes to freelunch. Versions follow [semantic versioning](https://semver.org/):
a minor release per usable feature, a major release only for breaking changes to the host
contract, the CLI or the project layout.

## [Unreleased]

The first release, planned as 1.0.0: deploy your project's container from its own repository.

### Added

- **Project mode.** `freelunch init` creates a `.freelunch/` folder in any repository, with a
  `terraform.tfvars.example` per stack, `apps.tfvars`, `.env.example` and a `.gitignore`.
  In that folder's tree every command reads tfvars and writes state, `inventory.json` and
  provider plugins in the project. Inside the freelunch checkout nothing changes.
- **`freelunch deploy`.** Copies each app's Compose file and env file to its host over SSH,
  logs in to private registries, runs `docker compose up --wait` and fails when a container
  stays unhealthy, then starts `cloudflared` and prunes unused images. Targets a host, a
  provider or everything; `--dry-run` prints the remote script with secrets left out.
- **Cloudflare glue stack** (`providers/cloudflare`): a remotely managed tunnel per host,
  proxied DNS records, optional Access email login per hostname, zone looked up by name.
  The tunnel token reaches the host through `deploy`, never through cloud-init.
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
  `tests/cli.sh` for init, project state and deploy against a fake ssh and docker.

### Changed

- The CLI loads credentials from `.freelunch/.env` (or `.env` in the checkout); variables
  already set in the shell win.
- `freelunch fmt` takes `-check`.
- `freelunch list` no longer reports a destroyed stack as deployed.
