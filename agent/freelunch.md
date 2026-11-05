# freelunch: deploy this project to a free cloud, from GitHub Actions

You are helping someone who may have only a browser: no terminal, no laptop. **Do not install
freelunch and do not run it.** It runs in GitHub Actions, as one step of the project's
CI/CD workflow. Your job is to write files into the repository and tell the person which
secrets to add in GitHub's web page. A push to `main` then builds, deploys and prints the URL.

## Hard rules

1. Never install, download or run freelunch, OpenTofu or Terraform in your sandbox.
2. Never write a secret into any file, commit, comment or message: no API tokens, keys,
   passwords or passphrases, not even an example that looks real. Secrets are GitHub secrets
   the person adds themselves.
3. Never use `pull_request_target`. Never give a workflow more `permissions` than the template.
4. Pin `freelunch-sh/freelunch` to one release tag or commit, never `@main`.
5. Say what you did and what the person still has to do, in plain words, one step at a time.

## Files you write

Start from this workflow: copy it to `.github/workflows/deploy.yml` and make its three
changes (the pin, the secrets the targets need, the platforms).

<!-- workflow-template -->

| File | Content |
|---|---|
| `Dockerfile` | The app's image. None? Write one for the stack you find (listen on `$PORT`, run as a non-root user, one process) |
| `compose.yaml` | `services:` with one service: `image: ghcr.io/<owner>/<repo>:${IMAGE_TAG:-main}`, its port, its environment variable *names* only |
| `.freelunch/version` | The pin: the release tag (or commit) of freelunch, on one line |
| `.freelunch/apps.tfvars` | `targets = ["northflank"]` and `apps = { <name> = { compose = "../compose.yaml" } }` |
| `.freelunch/northflank/terraform.tfvars` | `name_prefix = "<project>"`, `region = "europe-west"`, `plan = "nf-compute-20"` |
| `.freelunch/state.git.tfbackend` | `branch = "freelunch-state"` and `remote = "origin"` (the state is kept encrypted in that branch) |
| `.freelunch/.gitignore` | `*/terraform.tfstate`, `*/terraform.tfstate.*`, `*/.terraform/`, `.env`, `*.env` |
| `.github/workflows/deploy.yml` | The template, edited |

The default target is Northflank's free plan: it needs no domain (the app gets a public
address). Other targets, for when the person asks:
`oci` (Oracle Always Free, Arm), `cloud-run` (Google), `scaleway`; they need their own
`.freelunch/<target>/terraform.tfvars`, and a Cloudflare domain for a VM. `targets` lists them
in order of preference; `up` goes to the next one when a cloud has no room.

## Secrets the person adds (Settings > Secrets and variables > Actions > New repository secret)

| Secret | What it is | Needed when |
|---|---|---|
| `FREELUNCH_STATE_PASSPHRASE` | Any long random phrase they make up; it encrypts the state | Always |
| `NORTHFLANK_API_TOKEN` | Northflank: Team settings > API > Tokens > create, role with project and service access | `northflank` |
| `CLOUDFLARE_API_TOKEN` | Cloudflare token for the domain | A domain |
| `FREELUNCH_OCI_CONFIG`, `FREELUNCH_OCI_KEY` | The OCI profile block and the API private key | `oci` |
| `CLOUD_RUN_ACCESS_TOKEN` | Google access token | `cloud-run` |
| `SCW_SECRET_KEY` | Scaleway secret key | `scaleway` |

Each one the workflow's `env:` names must exist; list in the deploy step only the secrets the
chosen targets need. Give the person the link `https://github.com/<owner>/<repo>/settings/secrets/actions/new`
and the name to type. Tell them to paste the value into GitHub's page, never into the chat.

## Order of work

1. Look at the repository: language, how it starts, its port, whether a `Dockerfile` exists.
2. Write the files above. Open one pull request with them. The `check` job (no secrets) and
   the image build run on it; fix what they report.
3. Tell the person which secrets to add (the table), with the link, and wait until they say done. If one is forgotten, the deploy fails first with the names of the empty ones and the page to add them on (`ci needs`): relay that, and re-run the workflow when they've added them.
4. After merge, the `deploy` job runs. Read its log (`gh run view` or the Actions tab). On
   success it prints the app's URL; give it to the person. On failure, quote the one line
   that says why and fix the file it names.
5. `Settings > Environments > production`: suggest a required reviewer if others can push.

## When a deploy says no room

Exit code 75 means every target is out of capacity. Add another target to `targets` and its
tfvars, or re-run the workflow later: the run is safe to repeat.
