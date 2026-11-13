# One VM, several projects

**This separates your own projects. It is not a security boundary:** everyone who can SSH to the host can read every
project's secrets and data. Use it for projects that are all yours.

An Oracle account now gets one 2 OCPU / 12 GB Arm VM in all, and a small app leaves most of it idle. A second project
should find that machine and move in, instead of waiting for capacity the account no longer has.

## Who owns, who joins

- The project whose stack made the VM is its **owner**. Nothing changes for it: `/opt/freelunch/apps/<app>`, the
  Docker network `freelunch`.
- A project that joins is a **tenant**. Its apps live in `/opt/freelunch/apps/<project>--<app>` (Compose takes the
  folder name as the project name, so containers and volumes are told apart with no flag), its network is
  `freelunch-<project>`, its tunnel connector is `<project>--cloudflared`, and its jobs and backups are
  `freelunch-<project>--…`. App names can't contain `--` for that reason.
- A tenant keeps its **own Cloudflare tunnel**, so removing one project can't break another's address.
- The host is the source of truth for who is on it: `/opt/freelunch/tenants/<project>/` holds `apps` (a line per app:
  folder and memory limit in MB) and `jobs` (a line per job: name, timeout, heavy 0|1, the minutes of the week it starts
  at). The owner's is `_owner`. Every deploy rewrites its project's two files in one step.

## Join a host

`freelunch up` looks for it. When OCI is a target, the project has no host yet, and the tenancy already runs a machine
freelunch made that uses the whole free Arm allowance, `up` doesn't ask OCI for a second one. At a terminal it asks "main
(2 OCPU, 12 GB, quiet most of the week (p95 CPU 6%)) already runs in this tenancy … Put this project on it?"; yes writes
the lines below. Without a terminal it stops and prints them:

```hcl
project = "shop"                       # the name this project is filed under on the host and in backups
hosts = { oci-main = { address = "203.0.113.10", shared = true, arch = "arm64" } }
# and on each app: host = "oci-main"
```

Then `freelunch trust oci-main` (it finds the instance by its address, or give `--instance <ocid>`) and
`freelunch deploy`. Setting these by hand works the same. `up` needs the OCI CLI signed in to the tenancy for this.

## Limits

Every service of an app on a shared host needs a memory limit in its Compose file (`deploy.resources.limits.memory` or
`mem_limit`), which is what it reserves. Before anything is copied, `deploy` reads the host's memory and what every project
reserved and refuses when the total plus this project's would leave less than `shared_headroom_mb` free (default 1024,
set it in `apps.tfvars`), or when the disk is more than 85% full. `deploy --dry-run` prints who reserves what. An owner
app with no limit counts as unknown and is named.

## Jobs and locks

The deploy lock and the lock for heavy jobs are host-wide, so deploys of two projects queue and heavy jobs (backups
included) run one after another. The overlap warning of `deploy --dry-run`, `check` and `doctor` also compares the heavy
jobs of the other projects on the host.

## See it, leave it

```bash
freelunch host            # the projects, their apps, what they reserve and use now, the disk, heavy jobs in time order
freelunch host --json
freelunch destroy oci-main    # in a tenant project: takes this project off the host, and nothing else
```

`destroy <shared host>` removes the project's folders, volumes, units, network and registry folder, asks first, and
refuses an app with data and no backup unless `--discard-data`. The owner's `destroy` of the host stack refuses while
other projects are on it (`--evict-tenants` goes ahead); `up --move` of the owner's apps leaves them on the old host.

## Not live-tested

The search for the machine (OCI Search, `compute instance list-vnics`), the monitoring query behind "quiet most of the
week" and `trust` through a console of an instance this project does not own follow Oracle's documentation and have
run against fakes only.
