# Move a project that already uses freelunch to CI/CD

For a project with a `.freelunch/` folder that you deploy by hand today. After this, a push to
`main` builds the image, deploys to the first target with room, checks that the app answers,
and rolls back if it doesn't. Nothing is installed in CI by you: freelunch runs as one step
of a GitHub Actions workflow.

**Give this to your coding agent** (Claude Code, Codex, ...) in the project:

> Read https://raw.githubusercontent.com/freelunch-sh/freelunch/main/docs/adopt-in-ci.md and
> follow it for this project. Don't install freelunch and don't run it; write files, open a
> pull request, and tell me which GitHub secrets to add.

## For the agent

Rules: never install or run freelunch, OpenTofu or Terraform yourself; never write a secret
into a file, commit, comment or message; never use `pull_request_target`; pin
`freelunch-sh/freelunch` to the commit below, never `@main`.

The pin is the newest release tag of freelunch (`git ls-remote --tags --refs
https://github.com/freelunch-sh/freelunch 'v*'`); while there is none, the commit that `main`
points to (`git ls-remote https://github.com/freelunch-sh/freelunch main`, 40 characters). The
person may also give you one. Write it exactly, wherever this page says "the pin".

1. **Look first.** Read `.freelunch/` (`apps.tfvars`, each stack's `terraform.tfvars`, `version`,
   any `state.*.tfbackend`), the compose file, the Dockerfile, and `.github/workflows/`. Note
   the targets in use, where the image is built and pushed, and what the old workflows do.
2. **Move the pin.** Write the pin above into `.freelunch/version`.
3. **State.** The pipeline needs the state where CI reaches it. If `.freelunch/state.*.tfbackend`
   exists, keep it. If not, write `.freelunch/state.git.tfbackend`:
   ```
   branch = "freelunch-state"
   remote = "origin"
   ```
   and tell the person: the state of the stacks already deployed has to be copied into that
   store once, from a machine that has it (`freelunch state init git && freelunch state push`,
   needs a terminal and OpenTofu). Without that, CI would try to create everything again.
4. **Config in git, no secrets in it.** The tfvars and `known_hosts` are committed; a secret in
   one is a mistake. Remove `*/terraform.tfvars` and `known_hosts` from `.freelunch/.gitignore`
   (state, `.env` and `*.env` stay ignored). Secrets go to GitHub, step 6.
5. **The workflow.** Fetch
   https://raw.githubusercontent.com/freelunch-sh/freelunch/main/docs/workflow-template.yml
   and save it as `.github/workflows/deploy.yml`, replacing `FREELUNCH_PIN` with the pin,
   choosing `platforms` for the targets (`linux/arm64` for Oracle Arm VMs, `linux/amd64`
   otherwise, both when `targets` has both), and listing in the two `env:` blocks of the deploy
   job exactly the secrets the targets need (table in
   [`agent/freelunch.md`](../agent/freelunch.md)). Keep everything else as it is: the jobs,
   permissions and the rollback step are the point. Make the compose file's image
   `ghcr.io/<owner>/<repo>:${IMAGE_TAG:-main}` (lowercase owner and repo). If an older workflow
   builds the same image or runs `freelunch up` on push, delete it or remove its push trigger,
   so a push deploys once. If the image is private, `apps.tfvars` needs `registries` with a
   read-only token (`password_env = "GHCR_TOKEN"`), which is a secret too.
6. **Open one pull request** with these files. Its `check` job (no secrets) and the image build
   run on it: read the result (`gh pr checks`, or the Actions tab) and fix what they report.
7. **Tell the person, in plain words**, which secrets to add at
   `https://github.com/<owner>/<repo>/settings/secrets/actions/new` (name, what it is, where to
   copy it from), that they paste values into GitHub's page and never into the chat, and
   that `FREELUNCH_STATE_PASSPHRASE` is the passphrase the state is already encrypted with
   (if it has one: the line in `.freelunch/.env`), or a new long phrase for a new state. If
   a secret is missing, the deploy fails first and names it (`ci needs`): relay that.
8. **After merge**, read the deploy run's log. On success it ends with `up: live on ...: <url>`
   and `verify: <url> answers`; give the person the URL. On failure, quote the one line that
   says why and fix the file it names. Exit 75 means every target is out of capacity: add a
   target, or run the workflow again later (it is safe to repeat).

Then, if the person has a terminal and admin rights: `freelunch harden --reviewer <login>` makes
the `production` environment deploys run in, and CODEOWNERS for the workflows.

## What to report back

Say what changed, which secrets are still to add, and anything surprising in the old setup
(manual steps the workflow can't do: a state that isn't in a store yet, a volume that pins an
app to one host, a domain on a zone Cloudflare doesn't have). The freelunch project wants to hear what
didn't work: https://github.com/freelunch-sh/freelunch/issues
