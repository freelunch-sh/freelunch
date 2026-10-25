# Contributing

Thanks for helping. Issues and pull requests are both welcome; for anything bigger than a
fix, open an issue first so we can agree on the approach.

## Run the tests

Everything runs offline: providers are mocked, state comes from fixtures, and the deploy
tests use a fake `ssh` and `docker`. No cloud account needed.

```bash
bin/freelunch test        # every test suite, plus tests/cli.sh
bin/freelunch fmt         # format HCL (CI runs: bin/freelunch fmt -check)
git ls-files -z '*.sh' | xargs -0 shellcheck bin/freelunch
```

`bin/freelunch test providers/cloudflare deploy` runs only the suites under those folders
(`tests` is the CLI suite).

You need Terraform ≥ 1.7 or OpenTofu ≥ 1.8 (for `mock_provider`), `jq` and `bash`. The OCI
compute and Azure suites currently pass on Terraform only: they use mock features OpenTofu
handles differently. Porting them is a welcome contribution.

CI runs every suite on Terraform and the portable ones on OpenTofu, checks formatting, runs
shellcheck, checks that the README checklist matches the `provider.yaml` files, and builds
the runner image.

## Add or implement a provider

Follow [docs/adding-a-provider.md](docs/adding-a-provider.md). In short:

1. Copy `providers/_template` to `providers/<name>/` and fill in `provider.yaml`. Every
   free-tier claim needs a source and a `last_verified` date.
2. For an implementation: small modules, a `stack/` with a `terraform.tfvars.example`,
   free-tier limits enforced with preconditions, and offline tests with `mock_provider`.
3. Run `bin/freelunch catalog` and commit the README change with your PR.

## Pull requests

- Keep each PR to one change, and say how you tested it. If you applied it against a real
  account, mention the provider and the date.
- Defaults must stay inside the free tier. Anything billable needs an explicit
  `acknowledge_*` opt-in.
- Only copy code from compatibly licensed sources (MIT, Apache-2.0, BSD, MPL-2.0), with
  attribution. freelunch is Apache-2.0.
- Out of scope for now: LLM APIs and inference platforms, app-level SaaS such as auth or
  email, and anything that automates account creation or dodges a provider's terms.
- Add a line for your change under `## [Unreleased]` in `CHANGELOG.md`.

## Releases

A release is a pull request that renames `## [Unreleased]` in `CHANGELOG.md` to the new
version and the day, e.g. `## [1.2.0] - 2026-11-03`, with a new empty `## [Unreleased]`
above it. Once it is merged, the release workflow runs the tests, tags `v1.2.0`, pushes the
runner image and makes the GitHub release from that section. Every usable feature gets its
own minor release; a major one is only for breaking changes to the CLI or the project layout.
