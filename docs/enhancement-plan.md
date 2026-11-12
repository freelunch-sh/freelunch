# Enhancement plan

Written 2026-11-11. It joins every open gap (the plans in `private/`, [oci-wait-gaps.md](oci-wait-gaps.md),
the field run of 2026-11-09 that moved a real project from Northflank to an Oracle VM) with the
ideas agreed after it: day-two commands, backups, a shared host, alerts, a watch job. Section 10
is the groundwork for what comes after this foundation: a canvas where an architecture is
drawn from these building blocks and deployed. Design background: [architecture.md](architecture.md), [graph.md](graph.md),
[engines.md](engines.md), [ci.md](ci.md).

Tick a box when the step is built, tested and committed. Work top to bottom: later sections
use earlier ones (backups need the timers of section 4, the shared host needs both).

**Legend:** `[x]` done · `[ ]` to do · 🔬 spike: find out and write the answer under the box
before building · ⛔ needs the user (a real account, a secret, a click). Never tick a ⛔ box
yourself.

## How to work on this plan

Read this once before the first box.

**Where things are**

- The whole CLI is one file, `bin/freelunch` (bash, about 10,800 lines). Find a function with
  `grep -n '^name()' bin/freelunch`; line numbers move, names don't.
- Commands are dispatched in `main()` at the end of the file (`cmd_deploy`, `cmd_up`, ...). A
  new command needs: a `cmd_<name>` function, a line in that `case`, and its text in `usage()`.
  Check the two `case` lists above the dispatch too: one resolves secret references
  (`resolve_env_refs`), one syncs state (`sync_start`). Add the command where it needs them.
- Helpers to reuse, not rewrite: `die`, `log`, `rel`, `check ok|warn|fail`, `notify`, `meta`,
  `tfvar`, `tfvars_map`, `config_dir`, `state_root`, `stack_dir`, `is_deployed`,
  `is_configured`, `is_platform`, `ssh_options`, `shq`, `b64`, `cmd_hybrid`, `deploy_plan`
  (writes `$TMP/targets.json`), `engine_call`.
- The app schema is `variable "apps"` in `deploy/variables.tf`; the deploy plan is built in
  `deploy/main.tf` and read from `deploy/outputs.tf`. A new field in `apps.tfvars` is added
  there first, with a validation and a test in `deploy/tests/`.
- What runs on a VM is the script `remote_script` prints (its `put` and `up` functions).
  Apps live in `/opt/freelunch/apps/<app>/` with `compose.yaml` and `.env`.
- The catalogue: `providers/<name>/provider.yaml`, schema in `providers/_template/provider.yaml`,
  validation and README generation in `catalog/`. After any `provider.yaml` change run
  `bin/freelunch catalog` and commit the README change with it.

**Rules**

- bash 3.2 must keep working (macOS): no `mapfile`, no associative arrays, no `${var,,}`.
- Messages are plain sentences that name the area first and say what to do next, like the
  existing ones: `log "volume: $app has no Docker volumes on $VOL_HOST"`.
- Secrets never reach a dry run, a log or a committed file. Every new feature that handles
  one gets a test line with `lacks "$out" "<the secret>"`.
- Defaults stay inside the free tier. Anything that can cost money needs an explicit setting.
- Nothing here is run against a real account. Write provider facts from the provider's own
  docs or schema (`tofu providers schema -json` in a scratch folder), say so in the README of
  that provider ("not run live"), and never write `verified: live`.
- Do not edit `private/` except where section 1 says so. Do not push, tag or open a PR
  unless asked.

**Tests**

- `tests/cli.sh` holds the CLI tests: functions named `test_<what_it_checks>`, picked up
  automatically. Helpers: `new_project`, `up_project`, `deploy_in`, `up_in`, `cli_in`,
  `contains`, `lacks`, `equals`, `exists`, `absent`. Read two neighbouring tests before
  writing one.
- Fakes live in `$WORK/bin` (`ssh`, `docker`, `sudo`, `nc`, `fake-tf`, and fake provider
  APIs). The fake `ssh` runs the remote script on this machine and rewrites
  `/opt/freelunch/apps` to `$FAKE_ROOT/apps`. A new host tool (`systemctl`, `flock`, `df`)
  needs a fake that records its arguments in `$FAKE_LOG`.
- Run only what a step touches while building: `tests/cli.sh <pattern>` (a `grep -E` on test
  names), `bin/freelunch test deploy`, `bin/freelunch test catalog`.
- Before each commit: `tests/cli.sh` in full, `bin/freelunch fmt -check`,
  `git ls-files -z '*.sh' | xargs -0 shellcheck bin/freelunch`.

**Each step ends with**

- its tests passing, and the full suite green;
- the command in `usage()`, the README's CLI table and the doc the box names;
- one line under `## [Unreleased]` → `### Added` (or `### Fixed`) in `CHANGELOG.md`;
- one commit, message in the repo's style (`area: what changed`), and the box ticked in the
  same commit.

**Already built: do not build again**

- OCI cost nets: the `budget` module (`budget_alert_emails`), `doctor_oci_billing` (billing
  state, tenancy-wide storage, reserved IPs, load balancers), the cost line of `plan oci`,
  the month's bill in `status` (`oci_month_cost`).
- `.freelunch/billing.tfvars`: `spend_cap_usd`, `paid_fallback`, `credit_expires_<provider>`
  (`status_money`, `doctor_money`, `money_credits`).
- Waits: every availability domain per round, `capacity_fallbacks`, the reason a wait ended
  (SIGTERM, SIGHUP, vanished), `ci wait --cancel` without rewriting the bundle, the
  sleeping-machine notice between attempts.
- Moves: `up --move` with volumes copied between VMs, `rollback`, `volume pull|push`,
  `destroy` refusing unbacked volumes, the `trust` message for a restarted VM.
- `logs` for Northflank, `verify`, `check [node] --json`, `journey`, `harden`,
  `ci oidc aws|gcp|azure`, the git-branch state store.

---

## 1. The plans and the catalogue tell the truth

The field run of 2026-11-09 exercised OCI (capacity wait from a laptop, reviewed plans, an
in-place resize, `deploy`, `doctor`, `status`, the state store), Northflank (deploy, and a
redeploy during the rollback) and Cloudflare (tunnel, DNS, Access) on real accounts, at commit
`3ad40cf`. Nothing records it.

- [x] `providers/oci/provider.yaml`, `providers/northflank/provider.yaml`,
  `providers/cloudflare/provider.yaml`: add `verified: live`. First read how `catalog/`
  validates `verified` and make sure it is accepted for `engine: tofu` providers; extend the
  validation and its test in `catalog/tests/` if not. Run `bin/freelunch catalog`
- [x] In each of those three provider READMEs add a short "Live runs" section: date
  2026-11-09, commit `3ad40cf`, what was run (the list above, per provider) and what failed
  then and was fixed after without a live re-run: `trust` on a restarted VM, the `up`
  cutover order, moving an app's data
- [x] `README.md` Roadmap section: replace "Every live-account run is still to do" with what
  has run live and what has not (CI deploy, the installed pin, a free domain, the fixes above,
  every other provider)
- [x] `docs/oci-wait-gaps.md`: its header says "Nothing here is fixed yet". Mark each item
  fixed, open or moved to this plan (section 3), checking the code for each, not this list
- [x] `docs/engines-plan.md`: delete the first four boxes of "Later phases" (they only point
  at sections 9 to 12). Move the lines that say "not built on purpose" or "nothing for an
  engine to make" (HCP Terraform/Spacelift/Scalr, Filebase, the GPU providers) out of the
  checklists into a "Not building" list at the end, without boxes, keeping their reasons
- [x] `docs/engines-plan.md`: replace the five "Live-account run for each" boxes with one
  table at the end, a row per provider with a `verified: fake-api` or no `verified` and
  `status: ready`: provider, the exact command to run, what to look for. Generate the rows
  from the `provider.yaml` files
- [x] `private/ROADMAP.md` (git-ignored, so no commit): tick PR #25 and "Merge PR #25";
  tick the v0.2 lines that exist (`up`, `setup`, the git-branch state, per-secret passing);
  strike v0.2 Phase 7's "Removed: `ci init|secrets|restore|wait|resume`, FREELUNCH_BUNDLE"
  with a note that they were kept and the bundle made optional; note under Phase 2 that
  `offers:` was not built and the catalogue took `engine`/`jobs`/`verified` instead; tick
  three of the five v0.1 Phase 2 live checks with the date and commit; add a line at the top
  pointing here
- [x] `private/browser-only-checklist.md` (git-ignored): tick 8.4 for AWS, GCP and Azure
  (`ci oidc`), leaving the Oracle spike; check 5.1 against `ci init --set-secrets` and tick
  it only if the value is never written to disk or printed; remove "polling timeout" from
  5.5 (5.2 decided there is no polling); fix the test count

## 2. Day-two commands on every target

Today `logs` only knows Northflank, and nothing restarts an app, opens a shell in it or shows
whether a VM's disk is filling.

- [x] Refactor, no behaviour change: turn `vol_target` and `vol_ssh` into `app_target <area>
  <app> [host]` and `host_ssh <command>` (the area is the word error messages start with:
  `volume`, `logs`, ...), setting `APP_HOST`, `APP_ADDR`, `APP_USER`, `APP_KIND` and
  `APP_DIR` (the app's folder on the host; `/opt/freelunch/apps/<app>` for now, section 6
  changes it in this one place). `volume` keeps its messages and tests unchanged
- [x] `freelunch logs <app> [--lines n] [--follow] [--host h]` on a VM host:
  `docker compose --project-directory "$APP_DIR" logs --no-color --tail <n>` over SSH, pinned
  keys only. `cloudflared` is a valid app name. Northflank keeps its path; `--follow` there
  dies with "logs: --follow works on VM hosts; on Northflank use its dashboard". The last
  `die` of `cmd_logs` now says the app runs nowhere. Test: `test_logs_reads_a_vm_apps_logs`
- [x] `freelunch restart <app> [--host h]`: `docker compose restart`, then
  `docker compose up -d --wait --wait-timeout $FREELUNCH_DEPLOY_TIMEOUT` so it fails loudly
  with the last 50 log lines when the app stays unhealthy (the same output `up` in
  `remote_script` gives). On a platform: `engine_call <provider> restart` when the engine
  defines it, else die naming the provider's own way. Test: healthy, and `FAKE_UNHEALTHY`
- [ ] `freelunch shell <app> [--service s] [-- command...]`: with a command, run it with
  `docker compose exec -T <service> <command>` and return its exit code; without one, open
  `sh` with a terminal (`ssh -t`, without `BatchMode`). The service defaults to the one
  named like the app, else the only service, else die listing the services. VM hosts only;
  on a platform die with the provider's own command. Test with a command, and the
  service-choice errors
- [ ] Host numbers in `status`: extend `REMOTE_STATUS` to print one first line
  `#host|<disk used %>|<disk total GB>|<memory used MB>|<memory total MB>|<load 1m>` (from
  `df -P /`, `/proc/meminfo`, `/proc/loadavg`), and have `status_apps` print it under
  "Apps on <host>" as `disk 41% of 93 GB, memory 2.1 of 12 GB, load 0.10`. The app loop must
  skip that line. At 85% disk or more, add "nearly full: freelunch shell <app>, or docker
  system df on the host". Tests need a fake `df` and readable fake `/proc` values (make the
  script read them through variables the fake can point elsewhere)
- [ ] The same numbers in `freelunch check <host> --json` (`disk_percent`, `memory_used_mb`,
  `memory_total_mb`), and the host node is unhealthy at 95% disk with that reason. Update
  the node table in `docs/graph.md`
- [ ] Docs: a "Day two" section in `docs/deploy-a-container.md` covering logs, restart,
  shell and reading `status`

## 3. A capacity wait that survives a bad night

Read first: `retry_reason`, `transient_why`, the wait loop that calls them, `end_wait`,
`oci_instances`, and [oci-wait-gaps.md](oci-wait-gaps.md) items 1, 2, 4, 6, 8, 9.

- [ ] A lost `LaunchInstance` answer no longer ends the wait (gap 1). When an apply in a
  wait fails with a network error on `POST .../instances`, look for the VM before deciding:
  `oci compute instance list` in the plan's compartment, filtered by the display name the
  plan creates (both are in the saved plan's JSON), ignoring `TERMINATED` and `TERMINATING`.
  None found: treat it as `transient` and retry. Found: import it into the stack's state
  (find the resource address in `providers/oci/stack` and its compute module; import through
  the same wrapper the CLI uses for `apply`, so project tfvars and state paths apply), then
  plan again and continue. If the import fails, stop with the instance's OCID and the exact
  import command. Without the OCI CLI: stop as today, and say the CLI is what would have
  let it check. Extend `fake-tf`'s `post` error and add a fake `oci compute instance list`.
  Tests: not found retries, found adopts, import failure prints the command
- [ ] One attempt has a time limit (gap 2). `FREELUNCH_ATTEMPT_TIMEOUT` (seconds, default
  900; `0` turns it off). Run the attempt's plan and apply under a watchdog in bash (macOS
  has no `timeout`): a background timer that sends SIGINT to the tofu/terraform process,
  then SIGKILL 30 seconds later. An attempt that was cut off is handled like the box above
  (look for the VM, adopt or retry). Log "attempt N took longer than 15 minutes (the machine
  may have slept): stopped it and checked that no VM was made". Keep the existing rule that
  `tee` ignores SIGINT. Test with a `fake-tf` mode that sleeps past a 1-second limit
- [ ] After a wait lands on a fallback size (gap 4), say exactly what to do: print the two
  lines to put in `terraform.tfvars` (`ocpus`, `memory_in_gbs`) for that instance, and that
  `freelunch plan oci` afterwards should say "No changes"; then that raising them later is
  an in-place resize. With a terminal, offer to write them, and only do it when both values
  sit on their own lines inside that instance's block; otherwise print. Test both paths
- [ ] `doctor`: when a wait is running or approved for a stack whose `oci_auth` is a session
  token, warn that the wait ends when the session does (it already knows the session's end),
  and name the fix: an API key profile (`oci setup bootstrap`). Check first whether a
  warning like this exists and extend it instead of adding a second (gap 6)
- [ ] The "Pay As You Go is the usual fix" hint also says: if the upgrade page fails, open a
  request with Oracle support, and that the upgrade places a temporary card authorization
  (state no amount unless Oracle's own page gives one; link it) (gap 8)
- [ ] `freelunch upgrade` refuses while `wait_pid` finds a running wait in this project:
  "upgrade: a wait for capacity is running for <stack> (pid N), and replacing freelunch
  under it can break it. Stop it first (kill N), or wait for it to end". `--force` skips it.
  Add the same warning for submodule users to the upgrade notes in `docs/ci.md` (gap 9)
- [ ] ⛔ Live: confirm the wait workflow's real cadence on a private and a public repository
  and write both in `docs/ci.md` (gap 3)

## 4. Hooks, scheduled jobs and a lock on the host

Backups (section 5) and the shared host (section 6) need three small things on a VM: a step
before and after a deploy, a timer, and a way for heavy work to queue.

**Decided:** schedules are written in one small format, so freelunch can compare them:
`"hourly :MM"`, `"daily HH:MM"`, `"weekly <mon..sun> HH:MM"`, all UTC. A function
`schedule_oncalendar` turns one into a systemd `OnCalendar` value and `schedule_minutes`
into the minutes of the week it fires at. Anything else is refused with the three forms.

- [ ] `deploy/variables.tf`: per app, `pre_deploy`, `post_deploy` (optional strings) and
  `service` (optional string). Validation: no newline in a hook. Tests in `deploy/tests/`
- [ ] `remote_script`: for an app with `pre_deploy`, after `docker compose pull` and before
  `up -d`, run `docker compose run --rm -T <service> sh -c <hook>` (the new image, the app's
  env and volumes). A failing hook stops the deploy of that app before anything is replaced,
  and prints "!! <app>: pre_deploy failed, so the running version was left alone".
  `post_deploy` runs with `docker compose exec -T <service> sh -c <hook>` once the app is
  healthy; a failure fails the deploy and says the new version is running. The dry run
  prints the hooks. On a container platform a hook is an error from `deploy/` ("hooks run on
  VM hosts"), listed with the other `platform_problems`. Tests: order in `$FAKE_LOG`, a
  failing `pre_deploy` leaves `compose up` uncalled, the platform error
- [ ] Host locks. `remote_script` makes `/opt/freelunch/locks/` and runs the whole deploy
  under `flock -w 900 /opt/freelunch/locks/deploy.lock`, so two deploys to one host queue
  instead of pulling at once; if the lock isn't free in 15 minutes it fails saying another
  deploy holds it. Add a fake `flock` (run the command, log the lock file) and change the
  fake `ssh` to rewrite the whole `/opt/freelunch/` prefix to `$FAKE_ROOT/` (so
  `$FAKE_ROOT/apps` stays where tests expect it)
- [ ] `deploy/variables.tf`: top-level `jobs = map(object({ app, command, schedule,
  service = optional, heavy = optional(bool, false), timeout_minutes = optional(number, 60) }))`.
  Validations: the app exists, the schedule parses (do the format check in HCL with a regex,
  the same three forms), the name matches the app-name pattern
- [ ] `remote_script`: for each job on this host write
  `/etc/systemd/system/freelunch-<job>.service` and `.timer`, `systemctl daemon-reload`,
  `systemctl enable --now` the timer. The service runs
  `docker compose --project-directory <app dir> exec -T <service> sh -c <command>` with
  `TimeoutStartSec=<timeout>`; a `heavy` job is wrapped in
  `flock /opt/freelunch/locks/heavy.lock`. Timers whose job left `apps.tfvars` are disabled
  and removed (list `freelunch-*.timer`, compare). Jobs on a platform target are an error
  for now. Fake `systemctl`. Tests: units written, a removed job's timer removed, the lock
  only on heavy jobs
- [ ] `freelunch jobs`: per host, each job's schedule, last run, last result and next run
  (`systemctl show` for the timer and service). `freelunch jobs run <job>` starts one now
  and follows its output. Test both against the fake
- [ ] Overlap warning in `deploy --dry-run`, `check` and `doctor`: two `heavy` jobs on one
  host whose start times are within the longer one's `timeout_minutes` (using
  `schedule_minutes`) give "jobs: <a> and <b> on <host> can overlap (<times>); they will
  queue, not run together. To spread them: <a suggested time in the widest free gap>". The
  host's own 04:00 reboot window (`reboot_time` in docker-bootstrap; read the project's
  value) counts as a heavy job. Test: overlap found, suggestion is free of overlaps
- [ ] Docs: `deploy/README.md` (hooks, jobs, the schedule format), a paragraph in
  `docs/deploy-a-container.md`

## 5. Backups that live somewhere else, and a way back from nothing

Oracle's forums carry many reports of free instances and boot volumes removed without notice,
and the field run lost about 20 minutes of data moving a database by hand. Today the only
backup is a manual `volume pull` to the laptop.

**Decided**

- The tool is restic, run as a container on the host (no install): encrypted, incremental,
  with retention, and it speaks S3, so R2 and B2 both work.
- A backup goes to a bucket freelunch already knows (the bucket contract: a stack's
  `buckets` output or an engine record), named per app in `apps.tfvars`.
- The restic password is `FREELUNCH_BACKUP_PASSPHRASE`, from the environment or
  `.freelunch/.env` like every other secret. Without it, a project with backups fails at
  `deploy --dry-run` and `doctor`, naming the variable. It is never defaulted.
- Repository path in the bucket: `freelunch/<project name>/<app>`.

- [ ] 🔬 Pin the restic image by digest. Find the current release and its multi-arch digest
  from the registry (as `cloudflared` is pinned in `providers/cloudflare/apps/`), write tag,
  digest and the date in `shared/` next to where it is used. With no network: leave the tag,
  a `TODO(pin)` comment and a line under this box
- [ ] `deploy/variables.tf`: per app `backup = optional(object({ bucket, schedule,
  before = optional(string), keep_daily = optional(number, 7), keep_weekly =
  optional(number, 4), paths = optional(list(string), []) }))`. Validations: the bucket is a
  known bucket (reuse `unknown_buckets`), the schedule parses, the app has a volume or
  `paths`. On a platform target: an error ("backups run on VM hosts; on <platform> use its
  own snapshots"). Tests in `deploy/tests/`
- [ ] `remote_script`: for an app with `backup`, write `/opt/freelunch/bin/backup-<app>`
  (0700) and `/opt/freelunch/backup/<app>.env` (0600: the S3 endpoint, keys, repository and
  password, from `bucket_env`'s data and the passphrase), and a `freelunch-backup-<app>`
  service and timer through the section 4 code path, always `heavy`. The script: run
  `before` in the app's container if set (`exec -T`); resolve the mountpoints of the app's
  volumes (as `vol_pull` does) plus `paths`; `restic init` if the repository is new;
  `restic backup` with those mounted read-only; `restic forget --prune` with the keep
  settings; on success write the time to `/opt/freelunch/backup/<app>.last`, on failure
  `/opt/freelunch/backup/<app>.failed` with the last 20 lines. The dry run prints the script
  with every secret redacted. Tests: files and modes, the timer, `before` runs first, a
  failing `before` skips the backup and writes `.failed`, no secret in the dry run
- [ ] `freelunch backup [app]` runs the backup now and follows it; `freelunch backup list
  <app>` prints the snapshots (`restic snapshots`, id, time, size). Tests with a fake restic
  (the fake `docker` grows a `run ... restic` case)
- [ ] `freelunch restore <app> [--snapshot <id>] [--host h]`: stop the app, restore the
  snapshot (latest by default) into the volumes' mountpoints and `paths`, start the app,
  wait for healthy. Asks first unless `FREELUNCH_AUTO_APPROVE=1`; refuses when the volumes
  are not empty and neither `--snapshot` nor `--overwrite` was given. Restoring onto another
  host than the one that made the backup is the normal case, not an error. Tests: restore,
  the refusal, the stop/start order
- [ ] Backups in `status` (per app: "last backup 3 hours ago", or the `.failed` reason) and
  as a property of the app node in `check --json` (`backup_age_hours`). The node is
  unhealthy when the last backup is older than twice its schedule's interval, or failed
- [ ] `destroy` and `up --move` accept a fresh restic snapshot (younger than the schedule's
  interval) in place of a `volume pull` copy as proof that the data is safe; read
  `up_keeps_data` and the destroy guard first. `up --move` takes a backup just before it
  stops the old app
- [ ] `freelunch up --restore`: when `up` makes or picks a target on which an app with
  `backup` has empty volumes, restore its latest snapshot after the first deploy and before
  routes point at it. Print "up: restored <app> from the backup of <time>". Without the
  flag, `up` says the flag exists when it sees that case. This is the "Oracle removed my VM"
  path: test it as one journey (host gone from state, `up --restore` on the next target,
  data back, route moved)
- [ ] 🔬 SQLite without a gap: Litestream as a sidecar streams a database file to the bucket
  as it changes. Find out: does it need the app's Compose file changed (a shared volume), can
  freelunch add the sidecar as an override file, what does a restore look like, what is the
  current version and config format (litestream.io). Write the answer here; build only if
  the app's own Compose file can stay untouched
- [ ] Until then, document the safe way for SQLite: a `before` hook that makes a consistent
  copy (`sqlite3 <db> ".backup <copy>"`) and `paths` or the volume including the copy, never
  the live WAL file
- [ ] Docs: `docs/backups.md` (set up a bucket on R2 or B2, the passphrase, restore,
  `up --restore`, the SQLite note, what a platform target does not get), linked from the
  README, and a runbook section "The VM is gone"
- [ ] ⛔ Live: a backup to R2 from the Oracle VM, a restore onto a second host, the size of
  the restic image on arm64

## 6. One VM, several projects

An account now gets one 2 OCPU / 12 GB Arm VM in all, and a single small app leaves most of
it idle. A second project should find that machine and move in, instead of starting a wait
for capacity the account no longer has.

**Decided**

- Plain Docker, no Kubernetes: a namespace is a project's own folders, Compose project
  names, network and limits on the host.
- The project whose stack made the VM is its **owner** and keeps today's layout
  (`/opt/freelunch/apps/<app>`, network `freelunch`), so nothing that runs now moves.
- A project that joins is a **tenant**. Its apps live in
  `/opt/freelunch/apps/<project>--<app>` (Compose takes the folder name as the project name,
  so containers and volumes are namespaced with no extra flag), its network is
  `freelunch-<project>`, its tunnel connector is `<project>--cloudflared`.
- The host is the source of truth for who is on it: `/opt/freelunch/tenants/<project>/`
  holds `apps` (one line per app: `<folder> <memory MB>`) and `jobs` (one line per job:
  `<name> <schedule minutes...> <timeout> <heavy 0|1>`). The owner writes
  `/opt/freelunch/tenants/_owner/` the same way. Plain text, so the host needs no `jq`.
- This separates your own projects. It is not a security boundary: everyone who can SSH to
  the host can read every project's secrets. The docs say so in the first paragraph.
- A tenant keeps its own Cloudflare tunnel, so removing one project cannot break another's
  address.

- [ ] `deploy/variables.tf`: top-level `project` (string, the app-name pattern, no `--`),
  and in `hosts`: `shared = optional(bool, false)` and `arch = optional(string)`. A host
  with `shared = true` needs `address`, `arch` and a `project`. `targets` gets `shared` and
  `project` per host, and takes `arch` from the override when the inventory has none. Tests
- [ ] `providers/cloudflare/stack`: a route's host may be a shared host. Add
  `shared_hosts` (list of names) to the stack's variables, have the CLI pass the names from
  `apps.tfvars`, and count them as known in `unknown_hosts`. Tests in the stack's suite
- [ ] On a shared host every app must have a memory limit in its Compose file
  (`deploy.resources.limits.memory` or `mem_limit`; `deploy/` already reads these for
  Northflank plans, reuse that local). Missing: an error naming the app and both spellings.
  `targets` carries each app's limit in MB
- [ ] `app_target` (section 2) and `remote_script` use the tenant layout when the target is
  shared: folder `<project>--<app>`, network `freelunch-<project>`, connector folder
  `<project>--cloudflared`, job and backup unit names prefixed `freelunch-<project>--`.
  `REMOTE_STATUS` on a shared host lists only this project's folders. `volume`, `logs`,
  `restart`, `shell`, `backup`, `restore`, `jobs` work unchanged through `APP_DIR`. Tests:
  one fake host, an owner project and a tenant project both with an app named `api`,
  deployed in turn; both folders exist, neither deploy touches the other's files, each
  `status` shows only its own apps
- [ ] The tenant registry: every deploy rewrites its project's `apps` and `jobs` files under
  `/opt/freelunch/tenants/` (the owner under `_owner`) in one step (`.new` then `mv`, like
  `put`). A project's `destroy` of a shared target removes its folders, volumes, units,
  network and registry folder, and nothing else. Tests
- [ ] The room check, before anything is copied: read the host's memory total and every
  tenant's `apps` file over SSH; refuse when the sum of all limits plus this project's
  exceeds the total minus headroom (`shared_headroom_mb` in `apps.tfvars`, default 1024):
  "deploy: <host> has 12 GB; other projects reserve 9.5 GB and this one asks for 2 GB, which
  leaves less than the 1 GB kept free. Lower a limit, or use another target". An owner app
  with no limit counts as unknown and is named in a warning. Disk: refuse above 85% used.
  `deploy --dry-run` prints the table (project, app, reserved). Tests: fits, does not fit,
  unknown owner app
- [ ] The owner protects its tenants: `destroy` of a host stack whose host has tenants
  (asked over SSH; when it can't be asked, say so and stop) refuses with their names;
  `--evict-tenants` goes on. `up --move` of the owner's apps leaves tenants alone and says
  they stay. Tests
- [ ] Jobs across projects: the overlap check of section 4 reads every tenant's `jobs` file
  on the host, so two projects' heavy jobs are compared, and the suggestion avoids all of
  them. The `heavy.lock` and `deploy.lock` are already host-wide. Test with two projects
- [ ] `freelunch host [name]`: for a shared or owned host, the table of projects, their
  apps and reserved memory, measured use now (`docker stats --no-stream`, per folder
  prefix), disk, and the week's schedule of heavy jobs in time order. `--json` too. Test
- [ ] Finding the machine. In `setup` and in `up` when OCI is a target and this project has
  no host yet: ask the tenancy for running instances tagged `managed-by = freelunch`
  (`oci_search`, the compute module sets that tag) and compare with the A1 allowance in
  `providers/oci/provider.yaml`. When one exists and the allowance is used up, do not start
  a wait: with a terminal ask "<name> (2 OCPU, 12 GB) already runs in this tenancy and uses
  the whole free allowance. Put this project on it?"; without one, stop with the three
  lines to add to `apps.tfvars`. Yes writes `project`, the `hosts` entry (`shared`, address,
  `arch`) and reminds to `freelunch trust`. Tests with a fake search result: found and
  accepted, found without a terminal, none found (today's behaviour)
- [ ] `trust` for a shared host: the tenant project has no stack state for it, so `trust`
  takes the instance's OCID from the search above (or `--instance <ocid>`) to read the
  console keys. Read `cmd_trust` and `oci_console_keys` first. Test
- [ ] Measured idleness, as a second opinion in the question above and in `freelunch host`:
  the week's 95th-percentile CPU of the instance from OCI Monitoring
  (`oci monitoring metric-data summarize-metrics-data`, namespace `oci_computeagent`,
  metric `CpuUtilization`; confirm the exact query from `--help` and Oracle's docs before
  writing it). Shown as "quiet most of the week (p95 CPU 6%)". Silent when the CLI or the
  metric is missing
- [ ] Docs: `docs/shared-host.md` (who owns, who joins, limits, what is and is not
  isolated, jobs and the locks, leaving), a row in `docs/graph.md`, the README
- [ ] ⛔ Live: a second project on the existing VM, with a job from each

## 7. Alerts for more than the capacity wait

`notify` reaches the desktop, ntfy, Discord and Slack, but only a wait calls it.

- [ ] `notify_event <event> <message>`: sends through `notify` when the event is in
  `FREELUNCH_NOTIFY_EVENTS` (a comma list; default `wait,deploy,move,backup,watch,expiry`).
  Waits go through it too, with no change in what they send. Test the filter
- [ ] Deploys: in CI (or with `FREELUNCH_NOTIFY_DEPLOYS=1` elsewhere), a failed `deploy` or
  `up` sends "<project>: deploy to <target> failed: <the first line of the reason>" and a
  successful `up` that changed the target sends where the app is now. Never the log, never
  an env value. Tests
- [ ] Backups: the host script of section 5 posts to a URL in
  `/opt/freelunch/backup/notify.url` (0600, written by deploy when `FREELUNCH_NOTIFY` is a
  URL) when a backup fails, with the same three body formats as `notify` (text, Discord
  JSON, Slack JSON) written in POSIX shell. Test the script with a fake `curl`
- [ ] Expiry: one function, `expiry_lines`, collects what `status` already warns about one
  by one (service tokens, `credit_expires_*`, the OCI session) and adds free domains:
  `domain_expires_<name with dots as underscores> = "YYYY-MM-DD"` in `billing.tfvars`, shown
  like the credits. `status` and `doctor` print from it unchanged; section 8 sends it
- [ ] A monitor for every public address, when the project has an uptime provider. Read
  first how the UptimeRobot, StatusCake and Healthchecks.io providers create a check
  (`providers/*/api.yaml` or their stacks) and what the service contract gives. Then: when
  one of them is configured, each Cloudflare route gets an HTTP monitor named
  `<project>-<hostname>` unless the route sets `monitor = false`; removed routes lose
  theirs. `status` shows the monitor per URL. Fixtures and tests like the provider's own
- [ ] Docs: a "Notifications" section in `docs/ci.md` listing every event and its text

## 8. A watch job, and catalogue facts it can use

Oracle halved its free Arm allowance in mid-2026 with little notice. The catalogue recorded
it; nothing told a project that was affected. Budget alerts do not stop a charge, and several
free platforms put apps to sleep.

- [ ] Catalogue fields, optional, in `providers/_template/provider.yaml` and validated in
  `catalog/`: `always_on: "yes" | "no"`, `sleeps_after_minutes: <number>` (only with
  `always_on: "no"`), and for hosts `limits.compute.idle: { percent, days }`. Shown in the
  generated README checklist as "always on" or "sleeps after N min". Tests in
  `catalog/tests/`
- [ ] Fill those fields for every `status: ready` provider in the container, static and
  host categories, only from that provider's `notes`, its `sources` or a page you can cite
  with a date; leave a field out when you can't. OCI gets the idle rule its `notes` already
  state, with the source and the date
- [ ] `up` and `setup` use it: a target that sleeps is listed after always-on ones in the
  wizard and marked; `up --dry-run` says "<target> sleeps after N minutes without requests
  (the first request then waits)". Tests
- [ ] `freelunch watch [--strict] [--json]`: the checks below, printed as `check` lines; it
  sends one `watch` notification listing only what changed since the last run (the last
  result is kept in `.freelunch/watch.state`, and in the state store when there is one);
  exit 0 unless `--strict` and something failed
  - [ ] Free tier changed: for each configured provider, compare `free_tier`,
    `free_tier_type`, `card_required`, `limits`, `status` and `notes` in this version's
    `provider.yaml` with the newest release's (downloaded the way `upgrade` does it; read
    `switch_version` and `cmd_upgrade`). Report each difference in one line, and for
    `limits` whether the project's tfvars are now over the new value. Offline: say it
    could not check, and go on
  - [ ] Everything from `expiry_lines` (section 7) within 30 days
  - [ ] Backups older than twice their schedule, or failed (section 5)
  - [ ] Idle risk: for an OCI host, when the tenancy is Always Free only
    (`oci_billing_state`) and the week's p95 CPU (section 6) is under the catalogue's
    `idle.percent`: "Oracle may reclaim <host> as idle". A warning with no remedy offered:
    freelunch does not help keep a machine busy to dodge the rule
  - [ ] The month's bill above zero (`oci_month_cost`), and the spend cap when set
  - [ ] Disk at 85% or more on a host (section 2)
- [ ] `ci init`: a `watch` job (`--jobs=...,watch`, on by default with `--pipeline`): a
  weekly scheduled workflow that runs `freelunch watch`, writes the lines to the job
  summary, and needs only the secrets the checks use. Test the generated workflow, and
  that `ci needs` names what it lacks
- [ ] Docs: `docs/watch.md`, and one honest paragraph in the README's guardrails text: a
  budget alert reports a charge, it does not prevent one
- [ ] 🔬 A cap that prevents. OCI has compartment quotas (`oci_limits_quota` in the provider:
  policy statements that set a service's limits to zero or to a number). Find out from
  Oracle's quota documentation and the provider schema whether a pay-as-you-go tenancy can
  be held to the Always Free shapes with them (zero every compute family, then allow A1 up
  to the catalogue's `max_ocpus` and the micro shape), and what a refused launch looks like.
  Write the statements here. Then build `quota_guard = true` in the OCI stack as a module
  beside `budget`, mock-tested, off by default, with `doctor` reporting whether it is on
- [ ] ⛔ Live: the quota guard on the real pay-as-you-go tenancy; a launch outside it refused

## 9. Small commands that save a search

- [ ] `freelunch next`: the one command to run now, with a reason. It reuses what `status`
  and `doctor` already compute, in this order: no `.freelunch/` → `setup`; a stack without
  tfvars → the file to fill; nothing deployed and no wait → `up`; a wait running → `status`
  (and its attempt count); a host whose key isn't pinned → `trust <host>`; apps not deployed
  or not running → `deploy`; a move recorded and unfinished → `rollback` or `up --move`;
  otherwise "nothing to do: freelunch status shows the project". `--run` runs it after
  asking. A test per branch
- [ ] `freelunch fit [dir]`: where the app can run for free. Reads the Compose file's
  memory limits (the sum; "unknown" without limits), whether it has volumes, and the image
  architectures when the registry answers (`check_images`' code). Prints the `status: ready`
  host and platform providers as a table: fits or why not (memory over the free size,
  volumes on a platform that has none, no build for the architecture), always on or sleeps,
  card needed, `verified`. Data comes from `provider.yaml` (`limits`, the new fields) and
  the platform sizes `deploy/` knows; a provider with no numbers says "unknown", never a
  guess. Sorted: fits and always on first. Tests with two fixture Compose files
- [ ] `freelunch down`: `destroy all` in reverse layer order with one confirmation that
  lists everything it removes, the existing data guard, then the leftover check for each
  provider that has one (for OCI the tenancy-wide parts of `doctor_oci_billing`), ending
  "down: nothing of this project is left on <providers>" or the list of what is. On a
  shared host it removes this project's namespace only. Tests
- [ ] `freelunch upgrade --dry-run [version]`: no install, no pin. Prints the CHANGELOG
  sections between the pinned version and the target (from the downloaded copy), with any
  "Upgrading" section first. With `--plan` it also runs `plan` for each deployed stack with
  the new version's code and says per stack "no changes", or what it would change, replace
  or destroy (reuse what `plan --out` prints about replacements). Tests with two fake
  versions in `FREELUNCH_HOME`
- [ ] Short names: `aliases = { console = "shell api -- bin/console" }` in `apps.tfvars`;
  `freelunch <alias> [args]` runs it. An alias may not shadow a built-in command (error at
  `check`). `freelunch help` lists the project's aliases. Tests

## 10. Groundwork for the canvas

What comes after this foundation: a page in the style of draw.io where you drag building
blocks (a host, a platform, an app, a database, a bucket, a domain, a monitor) onto a canvas,
join them, and get that architecture deployed and shown live. The canvas itself gets its own
plan. This section only makes sure the foundation can be driven by one: everything a canvas
shows or changes has to exist as data, with no screen-scraping of command output.

The model is already there ([graph.md](graph.md)): every component is a node, a dependency
is an edge (`needs`, `bucket`, `database`, routes), `check --json` gives each node's health
and `journey --json` follows a path. What is missing is one document for the whole graph,
the palette of blocks, and a way to write a drawing back into the project.

**Not decided yet (the user's call, before the canvas plan is written)**

- Where the canvas runs: a static page that reads and commits to the project's repository
  through GitHub (fits the browser-only rule: nothing runs the CLI outside Actions), or a
  local `freelunch canvas` server.
- Build the canvas from a diagram library, or use draw.io itself with a custom shape
  library and read its file.

- [ ] `freelunch graph --json`: the whole project as one document. `nodes`: every host,
  platform, app, database, bucket, service, DNS zone, mesh, tunnel and route, each with
  `id`, `type`, `provider`, `target` (where it runs), its settings from the tfvars (no
  secret values: a secret is `{"secret": "<NAME>", "set": true|false}`) and `status`
  (`planned`, `deployed`). `edges`: `{from, to, kind}` for needs, bucket, database, route
  and runs-on, with the medium the resolver picked ([graph.md](graph.md), section 9c of the
  engines plan). Build it from what `deploy/`'s `graph` and `targets` outputs, the hybrid
  inventory and the engine records already hold; read `cmd_probe` and `cmd_journey` first
  and reuse their node list so the ids match `check`. Without `--json`: an indented text
  tree. Write the format in `docs/graph.md` with a version field (`"format": 1`). Tests: a
  project with a host, two apps, a database and a route; ids equal those of `check --json`;
  no secret in the output
- [ ] `freelunch graph --json --live` adds each node's health from the `check` probes
  (`exists`, `reachable`, `healthy`, `reason`) and, for hosts, the numbers of section 2.
  This is what a canvas polls to colour its blocks
- [ ] `freelunch catalog --json`: the palette. One entry per provider and node type it can
  make: `provider`, `display_name`, `category`, `node_types`, `engine`, `status`,
  `verified`, `free_tier`, `free_tier_type`, `card_required`, `always_on`,
  `sleeps_after_minutes`, `limits`, the secrets it needs (`secrets:` in `provider.yaml`),
  and its settings: for a `tofu` stack the variables of `stack/variables.tf` with type,
  default, description and whether required (read them with the tool's own parser, e.g. a
  `tofu` console or `-json` output in a scratch folder, not with regular expressions over
  HCL). Written to stdout; `bin/freelunch catalog` keeps generating the README. Tests in
  `catalog/tests/` and one CLI test that the output is valid JSON with every `ready`
  provider in it
- [ ] 🔬 Writing a drawing back. A canvas produces a graph document; the project is tfvars.
  Find the smallest safe way to go from one to the other: tofu and terraform both read
  `*.tfvars.json`, so a document could become `apps.tfvars.json` and
  `<stack>/terraform.tfvars.json` with no HCL writer at all. Check: does every place that
  reads tfvars today (`tfvar`, `tfvars_map`, the secret scan in `check`, `ci secrets`,
  `setup`) cope with the JSON form, and what happens when both forms exist. Write the
  answer and the chosen file layout here before the next box
- [ ] `freelunch graph apply <file|->`: take a graph document (the format above) and write
  the project's config from it, in the form the spike chose. It writes files only, never
  deploys. It refuses a document whose `format` it doesn't know, a node of a type or
  provider the catalogue lacks, an edge the resolver has no medium for, and any secret
  value in the document (secrets are named, never carried). `--dry-run` prints the files it
  would write as a diff. Round trip, as the main test: `graph --json` of a project, `graph
  apply` into an empty folder, `graph --json` again gives the same document
- [ ] `freelunch graph check <file|->`: the same validation without writing, as JSON:
  per node and edge `ok` or the reason, plus what `fit` (section 9) and the room check
  (section 6) say for each app. A canvas calls this while the user drags
- [ ] Layout is the canvas's business, kept apart from the config: positions live in
  `.freelunch/canvas.json` (node id to x, y), ignored by every command, never required.
  `graph apply` keeps the entries of nodes that still exist. Test
- [ ] The workflow from `ci init` can publish the live graph: an optional step that runs
  `freelunch graph --json --live` after a deploy and on the watch schedule, and uploads it
  as an artifact (and as the job summary's table). This is how a browser-only canvas gets
  live status without credentials of its own. Test the generated workflow
- [ ] Docs: the document format, the palette format and the round trip in `docs/graph.md`;
  a line in the README roadmap naming the canvas as what follows

## 11. Later, not in this pass

Kept here so they are not lost. Do not build them without being asked.

- A second environment (staging) of the same project, and previews per pull request
  (`private/browser-only-checklist.md` 6.5)
- Zero-downtime deploys on a VM (start the new container, check it, then switch)
- Menus and the per-offer catalogue (`private/ROADMAP.md` v0.2 Phases 2 and 3): decide
  whether they are still wanted before any work
- Host-key pinning from the serial console for GCP, AWS and Azure
- ZeroTier, ngrok, and the providers the engines plan lists as unchecked

## 12. Live runs ⛔

Each needs the user's accounts. Record every run in the provider's README "Live runs"
section (date, commit, what ran, what failed) and only then set or keep `verified: live`.

- [ ] ⛔ The fixes made after 2026-11-09, on the real VM: `trust` after a restart, `up --move`
  with a volume between two hosts, `rollback`
- [ ] ⛔ One deploy from GitHub Actions after an image build, with per-secret passing and no
  bundle
- [ ] ⛔ The first project moved off the submodule: `install.sh`, `freelunch init` (the pin),
  `freelunch ci init`
- [ ] ⛔ A free domain through `domain add` and `domain status`, serving the app
- [ ] ⛔ Sections 2 to 9: each section's own ⛔ box
- [ ] ⛔ Release `v0.1.0` once the four boxes above are ticked
