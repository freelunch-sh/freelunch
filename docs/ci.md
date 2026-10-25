# Run freelunch from CI

Everything in the [walkthrough](deploy-a-container.md) runs on your machine, which is fine
until it has to stay on. Waiting for Oracle's Arm capacity can take days, and a laptop
sleeps when its lid closes: `caffeinate` keeps a Mac awake only while the lid is open, so a
wait left overnight makes a handful of attempts during the Mac's short maintenance wakes.
The same goes for deploying from somewhere else, like a CI job after each new image.

A project runs the same anywhere once three things can travel:

- **Its state**, which lives in `.freelunch/<stack>/terraform.tfstate` and stays out of git.
  A [state store](#1-keep-the-state-in-a-store) keeps a copy that CI and your other
  machines reach, encrypted.
- **The files git doesn't have**: tfvars, `.env`, app env files, `known_hosts`, the OCI API
  key and the SSH key `deploy` signs in with. [`freelunch ci secrets`](#3-the-secret) puts
  them into one CI secret, `FREELUNCH_BUNDLE`, and `freelunch ci restore` unpacks it in the job.
- **Your approval**, for the one thing CI does without asking: a wait for capacity. You
  review the plan here and [hand the wait over](#4-wait-for-capacity-in-github-actions);
  CI then applies only what that plan does.

This page sets it up on GitHub Actions. [GitLab](#gitlab-ci), [other CI
systems](#other-ci-systems) and [a machine of your own that stays on](#another-machine-that-stays-on)
come after.

## What you need

- The project in a GitHub repository, with freelunch pinned as in the walkthrough.
- [gh](https://cli.github.com), signed in (`gh auth login`), on the machine you set this
  up from. It sets the secret and starts the workflows.
- OCI signing in with an **API key**. A session token from `oci session authenticate`
  ends hours after you sign in, and CI can't sign in again: `oci setup bootstrap
  --profile-name freelunch` makes a key ([how](../providers/oci/README.md#prerequisites)).

## 1. Keep the state in a store

Pick a store. Each is free, and freelunch talks to it through tofu/terraform's own
backends, so anything one of them supports works too.

| Store | Free | Card | `freelunch state init` |
|---|---|---|---|
| **OCI Object Storage** (recommended with an OCI host) | 20 GB and 50,000 requests a month, Always Free | no new one | `oci`: makes the bucket and its key |
| Cloudflare R2 | 10 GB | R2 asks for a payment method before the first bucket | `r2`: writes the settings to fill in |
| Backblaze B2 | 10 GB | no | `b2`: writes the settings to fill in |
| GitLab | its own state for the project | no | `gitlab`: for a project on GitLab |

With an OCI host, the store is one command away:

```bash
freelunch state init oci
freelunch state push          # copies each stack's state there; every command does from now on
git add .freelunch/state.s3.tfbackend && git commit -m "Keep the freelunch state in Object Storage"
```

`state init oci` uses the OCI CLI and the oci stack's profile to make a private bucket,
`<name_prefix>-freelunch-state`, with versioning on, so every earlier copy of the state can
be brought back. It reaches the bucket through Object Storage's S3-compatible API, which
takes a Customer Secret Key: it makes one for your user (a user can have two) and puts it
in `.freelunch/.env` as `FREELUNCH_STATE_AWS_ACCESS_KEY_ID` and
`FREELUNCH_STATE_AWS_SECRET_ACCESS_KEY`, with `FREELUNCH_STATE_KEY_MADE`, when it made it.
A new key takes a few minutes to work on all of Object Storage's servers, and until then some
requests get a 403 `SignatureDoesNotMatch` and others don't. For 10 minutes after the key was
made, state runs try again every 15 seconds while that happens, and say "key not active yet".

The settings go in `.freelunch/state.s3.tfbackend`, which you commit: the bucket, the
endpoint, and `{stack}`, which freelunch fills in with the stack's name, so each stack's
state is a file of its own (`oci.tfstate`, `cloudflare.tfstate`). For R2, B2 and GitLab,
`state init` writes the same file with what to fill in, and says where to get the key. Any
other backend works the same way: a file named `state.<backend>.tfbackend`, with the
backend's settings and `{stack}` in the key or address.

### The passphrase

State holds secrets: the cloudflare stack's has the tunnel tokens and service token
secrets. So the copy in the store is encrypted, with OpenTofu's state encryption (AES-GCM,
with a key made from a passphrase). `state init` puts a random passphrase in `.freelunch/.env`
as `FREELUNCH_STATE_PASSPHRASE`. Keep a copy of it somewhere safe as well, such as your password
manager: without it, nobody can read the copies, you included. `.env` can name it instead of
holding it (`FREELUNCH_STATE_PASSPHRASE=op://Private/freelunch/passphrase`).

Terraform has no state encryption. With Terraform, `state init` sets
`FREELUNCH_STATE_PASSPHRASE=none`, which keeps the copy as it is here; the store still keeps
it private. The files in `.freelunch/` stay unencrypted either way, as they always were.

### How the copies stay in step

Every command that reads state (plan, apply, destroy, deploy, status, output, trust, hybrid
and inventory) first takes the store's copy of a stack when it is newer than the one here.
apply and destroy copy the stack back when they finish, failed or not, and a wait copies it
after each attempt that changed it, so a run that ends between two attempts loses nothing.
The store's credentials reach those runs only: `FREELUNCH_STATE_AWS_ACCESS_KEY_ID` is
`AWS_ACCESS_KEY_ID` there and nowhere else, so it never gets mixed up with the aws stack's.

A copy only ever replaces an older one of the same stack: tofu/terraform refuse to push one
with a lower serial or another lineage. Two copies with the same lineage and serial are in
step, whichever tofu/terraform version wrote them. When two machines (or yours and CI)
changed the same stack since they last copied it, the next command that works on that stack
stops instead of choosing:

```
freelunch: state: oci changed both here (serial 14) and in the store (serial 15) since
freelunch last copied it, ...
```

Look at both, then keep one: `freelunch state push oci --force` keeps this machine's,
`freelunch state pull oci --force` takes the store's. A command that works on other stacks
only (`freelunch deploy northflank` when oci is the one at odds) says so and goes on with the
copy here. `freelunch state` shows where each stack stands, and `freelunch doctor` checks the
store too.

## 2. The workflows

```bash
freelunch ci init
```

This writes two workflows:

- `.github/workflows/freelunch-wait.yml` waits for capacity on a schedule. Each run makes one
  attempt with the plan you approved, and the workflow turns itself off once the host
  exists, or when there is nothing to wait for. It runs about every half hour in a private
  repository and every quarter of an hour in a public one, as GitHub finds room.
- `.github/workflows/freelunch.yml` runs `freelunch deploy` after the image workflow
  (`freelunch init --image-workflow`) pushes a new image of `main`, and any other command you
  start from the Actions tab or with `gh workflow run freelunch.yml -f run="status"`.

Both use the action in this repository (`uses: freelunch-sh/freelunch@<tag>`), which sets up
the same tofu or terraform version you have, unpacks the bundle and runs the command. With
freelunch as a submodule, they use the submodule's copy (`uses: ./freelunch`), so the
workflows always run the version the project pins. Commit and push both files.

## 3. The secret

```bash
freelunch ci secrets
```

This puts everything a job needs that git doesn't have into the repository secret
`FREELUNCH_BUNDLE`, compressed, and lists what went in:

- each stack's `terraform.tfvars`, and the app env files `apps.tfvars` names;
- `.freelunch/.env`, with the secrets that come from 1Password or the keychain read now,
  since CI has neither, and the variables the project uses that only your shell sets
  (`CLOUDFLARE_API_TOKEN`, for one);
- `.freelunch/known_hosts`, the host keys you pinned;
- the OCI profile the oci stack signs in with, and its API key;
- the SSH key `deploy` signs in with: `FREELUNCH_SSH_KEY`, or the `~/.ssh/id_*` key that
  `ssh_public_keys` has. A key with a passphrase stays out, as CI can't type it; make one
  without for CI, and add its `.pub` to `ssh_public_keys`.

State never goes in it: CI takes that from the store. Run `freelunch ci secrets` again
after you change any of those files, so CI has the same as you. In a job, the values of the
env files are masked in the log.

## 4. Wait for capacity in GitHub Actions

Review the plan here, then hand the wait over:

```bash
freelunch plan oci --out .freelunch/oci/reviewed.tfplan
freelunch ci wait oci --plan .freelunch/oci/reviewed.tfplan
```

`ci wait` copies the oci state to the store, so CI starts where you are, and approves what
the plan changes: `.freelunch/oci/approved.json` lists each resource and action, with a
checksum of the tfvars the plan was made with. The approval goes into `FREELUNCH_BUNDLE`,
and `ci wait` turns the wait workflow on and starts its first run.

Each run then makes one attempt. It plans, and applies the plan only when it destroys
nothing and makes no change the approval doesn't list; tfvars that changed since the plan
was approved stop it too. Every attempt is in the next availability domain, numbered after
the run. While OCI is out of capacity, a run passes and the next one goes on; when the host
exists, the run says so, `FREELUNCH_NOTIFY` (ntfy, Discord or Slack, from `.env`) gets a
message, and the workflow turns itself off. A wait that stops for another reason fails the
run, so GitHub tells you. The workflow stays on, since what stopped one run may be gone by
the next, until three runs in a row have failed; then it turns itself off, and once you have
fixed the cause, `freelunch ci wait oci` (without `--plan`, as the approval is still there)
turns it on again.

```bash
freelunch status        # oci: waiting for capacity in CI since 2026-10-24T10:12:03Z (freelunch ci wait) ...
gh run list --workflow freelunch-wait.yml
freelunch ci wait oci --cancel
```

While CI waits for a stack, freelunch doesn't apply or destroy that stack here, since both
could make the host. Once the state shows the host, `freelunch status` says the wait is
over, and the stack is yours again. `--cancel` stops the wait: it takes the approval out of
the bundle and turns the workflow off.

A run takes a minute or two. In a public repository GitHub runs them for free; a private
one on GitHub Free has 2,000 minutes a month, which lasts about 20 days of a run every half
hour. Change the `cron` line to wait less often. The schedule is a wish, not a promise:
GitHub starts scheduled runs when it has room, so a run can come an hour or two late, and
now and then not at all.

## 5. Deploy from GitHub Actions

With the image workflow, every new image of `main` is deployed by the `freelunch` workflow,
and `gh workflow run freelunch.yml` deploys whenever you like. In CI, `deploy` only talks to
hosts whose key `.freelunch/known_hosts` has (`FREELUNCH_SSH_STRICT=1`, which the bundle sets),
since a job that trusted the first key it sees would trust a new one every run. Pin a new
host's keys here, with `freelunch trust oci-main` or a first `deploy`, then run
`freelunch ci secrets`.

A runner reaches your host the way you do: port 22 has to be open to it. With
`ssh_source_cidrs` narrowed to your own address, or closed for Tailscale, the runner needs a
way in, such as [Tailscale's GitHub Action](https://github.com/tailscale/github-action) in
the workflow before the freelunch step. A container platform such as Northflank needs nothing
of the sort: `deploy` goes through its API with the token from `.env`.

## GitLab CI

```bash
freelunch state init gitlab     # GitLab's own state for the project, or any store above
freelunch ci init gitlab        # .gitlab-ci.yml, or .gitlab/freelunch.yml to include
freelunch ci secrets --print    # the value for the CI/CD variable FREELUNCH_BUNDLE
```

The pipeline runs freelunch in its runner image (`ghcr.io/freelunch-sh/freelunch`), which has
OpenTofu, so the project should use OpenTofu too. Add `FREELUNCH_BUNDLE` under *Settings >
CI/CD > Variables*, masked. A variable holds 10,000 characters, enough for a typical
project's bundle; `ci secrets --print` says how big yours is. Running the pipeline deploys (`FREELUNCH_RUN` sets the command). To wait for
capacity, add a pipeline schedule (*Build > Pipeline schedules*) every 30 minutes with the
variable `FREELUNCH_RUN` set to `ci resume`, after `freelunch ci wait`; GitLab can't turn the
schedule off from the job, so turn it off once the wait is over. With GitLab's own state,
the job signs in to it with its job token.

## Other CI systems

Any CI that runs a container can run the runner image the same way: the project's checkout
as the working directory, `FREELUNCH_BUNDLE` from the CI's secrets in the environment, then

```bash
/opt/freelunch/bin/freelunch ci restore
/opt/freelunch/bin/freelunch deploy        # or ci resume, on a schedule, for a wait
```

`ci resume` makes one attempt for each approved wait. Out of capacity, it exits 0, for the
next scheduled run to go on; a wait that stopped for another reason exits 1. It numbers the
attempt after `GITHUB_RUN_NUMBER` or `CI_PIPELINE_IID`; elsewhere, set
`FREELUNCH_WAIT_ATTEMPT` to a number that grows with every run, so each run tries the next
availability domain. `FREELUNCH_CAPACITY_TIMEOUT` lets one run make more attempts, for that
many seconds.

## Another machine that stays on

A home server, a Raspberry Pi or a VM you already have can wait as well as CI, with no
schedule: give it the same files and the same store, then let it wait in the background.

```bash
# here
freelunch ci secrets --print > bundle.txt        # copy it over, then delete it

# there, in a clone of the project
FREELUNCH_BUNDLE="$(cat bundle.txt)" freelunch ci restore && rm bundle.txt
freelunch plan oci --out .freelunch/oci/reviewed.tfplan
freelunch apply oci --plan .freelunch/oci/reviewed.tfplan --wait-for-capacity --detach
```

When the host exists, it notifies you, and the state is in the store for your laptop's next
command. Outside CI, `ci restore` leaves a file alone that the machine has already and that
differs from the bundle's, such as its own `~/.oci/config`, and says so; `ci restore --force`
writes the bundle's.

## Other clouds

The bundle carries the OCI sign-in. GCP, AWS and Azure sign in with credentials on your
machine that freelunch leaves out (a `gcloud` login, `~/.aws`, `az login`): give CI its own
through `.freelunch/.env`, on one line each, then run `freelunch ci secrets`. For GCP, a
service account key as `GOOGLE_CREDENTIALS` (`jq -c . key.json` puts it on one line); for
AWS, `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`; for Azure, a service principal as
`ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID` and `ARM_SUBSCRIPTION_ID`.

## Troubleshooting

| Symptom | Look at |
|---|---|
| `FREELUNCH_STATE_PASSPHRASE is not set` | `.freelunch/.env` lacks the passphrase, here or in the bundle. `state init` writes one; for a store you set up yourself, add one of 16 characters or more |
| `the store's copy isn't encrypted yet` | The passphrase came after the first copy. `freelunch state push oci --force` replaces it with an encrypted one |
| `doesn't open with FREELUNCH_STATE_PASSPHRASE` | Another passphrase encrypted it: the bundle or `.env` on one machine is out of date |
| `oci changed both here ... and in the store` | Two machines changed the stack at once. Compare both, then `state push --force` or `state pull --force` |
| `key not active yet` | The Customer Secret Key `state init oci` made is minutes old and doesn't work on all of the store's servers yet. freelunch tries again for 10 minutes after it was made; after that, run the command again shortly |
| `the store turned down the key` | A key older than that is wrong or was deleted: compare `FREELUNCH_STATE_AWS_ACCESS_KEY_ID` in `.freelunch/.env` with Profile > Customer secret keys in the OCI console |
| `CI waits for capacity for this stack` | `freelunch ci wait` handed it to CI. Wait for it, or `freelunch ci wait oci --cancel` |
| `has changed since the plan was approved` | The tfvars in the bundle aren't the ones the plan was made with. Plan again, then `freelunch ci wait` with the new plan |
| `its host key isn't pinned` (in CI) | Pin it here (`freelunch trust <host>`), then `freelunch ci secrets` |
| `couldn't turn freelunch-wait.yml off` | The workflow lacks `permissions: actions: write`; turn it off in the Actions tab |
| A run waits for minutes before it starts, or comes hours late | GitHub starts scheduled runs late when it is busy, now and then not at all; the next one goes on |
| `three runs in a row failed, so freelunch-wait.yml is off` | Fix what the runs' logs show, then `freelunch ci wait oci` turns it on again with the same approval |
| `encrypting state takes OpenTofu` | `FREELUNCH_TF` isn't OpenTofu: the message says what its `version` printed. With Terraform, set `FREELUNCH_STATE_PASSPHRASE=none` |
