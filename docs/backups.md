# Backups

Oracle's forums carry many reports of free instances and boot volumes removed without notice,
and a VM's Docker volumes live on that one disk. A backup puts a copy of an app's data in a
bucket you already have, encrypted, so a new VM can start from it.

freelunch uses [restic](https://restic.net), run as a container on the host (nothing to
install): encrypted, incremental, with retention, and it speaks S3, so Cloudflare R2 and
Backblaze B2 both work.

## Set it up

1. **A bucket.** Any bucket freelunch knows: `buckets` in the `cloudflare` stack (R2) or the
   `backblaze-b2` stack. See [R2 buckets](../providers/cloudflare/README.md#r2-buckets) and
   apply the stack.
2. **A passphrase.** `FREELUNCH_BACKUP_PASSPHRASE` in `.freelunch/.env` (or the shell). It
   encrypts the backups. It is never defaulted, `deploy` and `doctor` stop without it, and
   **nobody can read the backups without it, you included**: keep a copy somewhere safe too.
3. **The app.** In `apps.tfvars`:

   ```hcl
   apps = {
     api = {
       host    = "oci-main"
       compose = "../compose.yaml"      # with a named volume (volumes: at the top)
       backup = {
         bucket      = "cloudflare-backups"   # <provider>-<name> of a bucket
         schedule    = "daily 02:00"          # hourly :MM | daily HH:MM | weekly <mon..sun> HH:MM, UTC
         before      = "bin/dump"             # optional: runs in the app's service first
         keep_daily  = 7                      # optional, the default
         keep_weekly = 4                      # optional, the default
         paths       = ["/srv/uploads"]       # optional: folders on the host, besides the volumes
       }
     }
   }
   ```

   An app needs a named volume or `paths` to have anything to save. Set `project = "shop"`
   in `apps.tfvars` so that the repositories keep their name in CI too (without it freelunch
   uses the project folder's name, which a CI checkout doesn't have: a CI deploy refuses without it, and `freelunch ci init`
   writes it). The repository of an app is
   `freelunch/<project>/<app>` in the bucket.

4. `freelunch deploy`. It writes the backup script, its settings (mode 0600) and a timer on
   the host; the backup runs behind the host's lock for heavy jobs, so backups and other heavy
   jobs never run together. `freelunch deploy --dry-run` shows the script with every secret left out.

## Use it

```bash
freelunch backup              # back every app up now and follow it
freelunch backup api          # one app
freelunch backup list api     # the snapshots: id, time, size
freelunch status              # "backup of api: last 3 hours ago", or why the last one failed
freelunch check --json        # backup_age_hours on the app; older than twice its interval = unhealthy
```

## Restore

```bash
freelunch restore api                      # the latest snapshot
freelunch restore api --snapshot a1b2c3d4  # one of freelunch backup list api
freelunch restore api --host oci-edge-1    # on another host
```

It stops the app, puts the snapshot into its volumes (and `paths`), starts it and waits for it
to be healthy. It asks first (or `FREELUNCH_AUTO_APPROVE=1`). Volumes that already have files
in them are not replaced unless you name a snapshot or give `--overwrite`, which empties them
first. Restoring on another host than the one that made the backup is the normal case: deploy
the app there first, so its volumes and the backup settings exist.

## Runbook: the VM is gone

Oracle removed the VM, or you destroyed it. The data was in a volume on it.

1. `freelunch up --restore`. `up` takes the next target with room (it may be a new Oracle VM,
   after a wait for capacity), deploys the app, and, because the app's volumes are empty and
   its bucket holds a backup, puts the latest snapshot in **before** the address moves to the
   new host. It prints `up: restored api from the backup of <time>`. Without `--restore`, `up`
   says that the backup exists and how to use it.
2. If `up` was done already and the app runs empty: `freelunch restore api --overwrite`.
3. Check: `freelunch check`, `freelunch backup list api`.

You need `FREELUNCH_BACKUP_PASSPHRASE` and the bucket's keys (in the stack's state, or from
the state store) on the machine you do this from. That is why the project keeps its state in
a store (`freelunch state init`).

`destroy` and `up --move` count a restic snapshot younger than the backup's schedule interval
as proof that the data is safe, in place of a copy from `freelunch volume pull`. `up --move`
takes a backup just before it stops the old app, when the old host has one set up.

## SQLite

Copying a live SQLite file, or its write-ahead log, can give a backup that does not open. Make
a consistent copy in `before` and back the copy up, not the live files:

```hcl
backup = {
  bucket   = "cloudflare-backups"
  schedule = "daily 02:00"
  before   = "sqlite3 /data/app.db \".backup /data/app.db.bak\""
}
```

The volume holds `app.db.bak` next to the live files, so the snapshot has a copy that opens (restore
it by renaming it). The container needs the `sqlite3` command. Streaming a database as it changes
(Litestream) is not built.

## What a platform does not get

Backups run on VM hosts. On a container platform (Northflank, Cloud Run, Scaleway) `backup` is
an error at `deploy`: use the platform's own snapshots, or keep the data in a bucket or a managed
database. A platform's volumes are not copied over SSH either (`freelunch volume` says so).

Not run live yet: a backup to R2 from the Oracle VM, a restore onto a second host, and the size
of the restic image on arm64 (the pinned image is 16.8 MB compressed, from Docker Hub's registry).
