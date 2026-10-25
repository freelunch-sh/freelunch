# Backblaze B2

| | |
|---|---|
| **Status** | ✅ Implemented |
| **Category** | Object storage |
| **Layer** | `service`: private buckets for apps, read by `freelunch deploy` |
| **Free tier** | ♾️ Always free: the first 10 GB |
| **Card required** | no |
| **Terraform provider** | [`Backblaze/b2`](https://registry.terraform.io/providers/Backblaze/b2/latest) `>= 0.12, < 1.0` |
| **Last verified** | 2026-10-25 |

B2 keeps an app's files where a restart or a new host can't lose them: results it is sent,
uploads, backups. Each bucket is private and has a key of its own that only reaches it, and
`freelunch deploy` puts the bucket's S3 settings into the environment of the app that names
it, on a VM or on a container platform such as [Northflank](../northflank/).

## What's free

| Resource | Free | Enforced by freelunch |
|---|---|---|
| Storage | **10 GB** in all, always | old versions of a file are deleted after a day (`keep_old_versions_days`), so they don't fill it |
| Downloads | up to 3 times the average stored a month | no |
| Buckets | private only | ✅ every bucket is `allPrivate` |

B2 needs no card for the free 10 GB. Free tiers change, so check the
[pricing page](https://www.backblaze.com/cloud-storage/pricing) before relying on this.

## Application key

Sign up at [backblaze.com](https://www.backblaze.com/sign-up/cloud-storage), then make an
application key under *Application Keys → Add a New Application Key* with access to all
buckets and *Read and Write*, which can make buckets and keys. The stack uses it; apps only
ever get their bucket's own key. Put it in `.freelunch/.env`, or name it in 1Password or the
macOS keychain there:

```bash
B2_APPLICATION_KEY_ID=004...
B2_APPLICATION_KEY=K004...
# B2_APPLICATION_KEY=op://Private/Backblaze/key
```

## Usage

```bash
freelunch init backblaze-b2      # adds .freelunch/backblaze-b2/ and keeps everything else
cp .freelunch/backblaze-b2/terraform.tfvars.example .freelunch/backblaze-b2/terraform.tfvars
freelunch apply backblaze-b2     # the buckets and their keys
freelunch deploy                 # the apps, with their buckets' settings
```

```hcl
# backblaze-b2/terraform.tfvars
buckets = {
  results = {}                                  # <name_prefix>-results
  # backups = { name = "acme-backups-2026" }    # a name of its own
}

# apps.tfvars
apps = {
  api = { host = "northflank-main", compose = "../compose.yaml", bucket = "backblaze-b2-results" }
}
```

Bucket names are unique across all of Backblaze, so `name_prefix` (the project's name, from
`freelunch init`) goes in front; when one is taken, give the bucket a `name` of its own.

The app gets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`,
`AWS_ENDPOINT_URL_S3` and `S3_BUCKET`. The AWS SDKs, boto3 and the aws CLI read the first
four on their own, so the app only has to use `S3_BUCKET`. On a VM they go into the app's
`.env` ahead of its `env_file`, so the Compose service needs `env_file: .env`.

## Inputs

| Name | Default | Description |
|---|---|---|
| `buckets` | `{}` | Buckets to make, keyed by name; `name` gives the whole bucket name |
| `name_prefix` | `freelunch` | Goes in front of each bucket's name |
| `keep_old_versions_days` | `1` | Days B2 keeps a file's older versions after it is overwritten or deleted |

## Outputs

`buckets` (provider, name, bucket, S3 endpoint and region per bucket) and `bucket_keys`
(sensitive, `backblaze-b2-<name>` → access key ID and secret), the
[storage contract](../../docs/architecture.md#storage-contract) that `freelunch deploy` reads.

## Caveats

- **The keys are in the state.** Like the tunnel tokens of the cloudflare stack, each
  bucket's key is in `.freelunch/backblaze-b2/terraform.tfstate`, which is git-ignored, and in
  the state store when the project has one.
- **destroy deletes the buckets only when they are empty.** B2 refuses to delete a bucket
  with files in it, so empty it in the dashboard first.
- **Not live-tested yet.** The stack follows the provider's schema and passes the offline
  tests. Please open an issue with what you find.

## Tests

| Suite | Covers |
|---|---|
| `stack/tests/plan.tftest.hcl` | Private buckets named after the project, old versions cleaned up, keys restricted to their bucket, the storage contract, names B2 refuses |
| `deploy/tests/deploy.tftest.hcl` | An app's bucket becomes its S3 settings; a bucket no stack made stops the deploy |
| `tests/cli.sh` | The settings in the app's `.env` on a VM and its environment on Northflank, left out of the dry run |
