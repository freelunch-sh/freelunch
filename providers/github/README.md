# GitHub

| | |
|---|---|
| **Status** | ✅ Built into the CLI (the workflows are tested; not run on a real account by the tests) |
| **Category** | IaC state, CI & registries |
| **Engine** | `ci` (built in) |
| **Free tier** | Actions minutes, GHCR for public images, Pages |
| **Card required** | no |

GitHub is the default of freelunch: `freelunch ci init` writes the provisioning, CI and deploy workflows,
hands the secrets over with `gh`, and can start a first dry run and a journey in Actions. Its container
registry, GHCR, is where `freelunch init --image-workflow` pushes by default, signed in with the job's own
token. The project's state can live in a branch of the repository (`freelunch state init git`). See
[docs/ci.md](../../docs/ci.md).
