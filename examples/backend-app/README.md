# backend-app

A minimal project that freelunch deploys: one container on an Always Free Oracle Cloud VM,
served at `https://api.example.com` through a Cloudflare Tunnel. The only open port on the
VM is SSH.

| File | What it is |
|---|---|
| [`compose.yaml`](compose.yaml) | The app. Swap the image for your own backend. |
| [`.freelunch/apps.tfvars`](.freelunch/apps.tfvars) | Which app runs on which host |
| [`.freelunch/oci/`](.freelunch/oci/) | The OCI host: one Arm VM, no open ports |
| [`.freelunch/cloudflare/`](.freelunch/cloudflare/) | The tunnel and DNS record for `api.example.com` |
| `.freelunch/.env` | Your Cloudflare token (and registry token), git-ignored |

In your own repository, `freelunch init` creates the `.freelunch/` folder. Here it is
already done.

## Before you start

- An OCI account with an API key in `~/.oci/config` (`oci setup bootstrap` creates one), or
  a session token from `oci session authenticate` (uncomment `oci_auth` and
  `oci_config_profile` in the OCI tfvars)
- A domain on Cloudflare and an API token for it (see
  [providers/cloudflare](../../providers/cloudflare/README.md#api-token)). A free name works:
  [docs/free-domains.md](../../docs/free-domains.md)
- An SSH key pair

Fill in the config:

```bash
cp .freelunch/oci/terraform.tfvars.example .freelunch/oci/terraform.tfvars
cp .freelunch/cloudflare/terraform.tfvars.example .freelunch/cloudflare/terraform.tfvars
cp .freelunch/.env.example .freelunch/.env
$EDITOR .freelunch/oci/terraform.tfvars .freelunch/cloudflare/terraform.tfvars .freelunch/.env
```

## The five commands

`freelunch` here is `../../bin/freelunch`; in your own repository it is the installed
command or the runner image (see the [walkthrough](../../docs/deploy-a-container.md#1-install-freelunch)).

```bash
freelunch init                # creates .freelunch/ (already done in this example)
freelunch apply oci           # the VM, with Docker
freelunch apply cloudflare    # tunnel + DNS for api.example.com
freelunch deploy              # copies compose.yaml to the VM, starts it and cloudflared
freelunch destroy all         # removes the tunnel, DNS record and VM
```

If `apply oci` stops at "Out of host capacity", run `freelunch apply oci --wait-for-capacity`:
it tries again, in every availability domain, until OCI has room for the VM. With a plan you
reviewed (`plan oci --out`), it can wait in the background (`--detach`) and notify you, or
in GitHub Actions, which doesn't sleep like a laptop (`freelunch ci wait`, see
[Run freelunch from CI](../../docs/ci.md)). Or run the app on Northflank's free plan
instead, with no VM:
[switch to another provider](../../docs/deploy-a-container.md#switch-to-another-provider).

Then open `https://api.example.com`. To ship a new version, change the image tag in
`compose.yaml` and run `freelunch deploy` again. The VM stays.

The [walkthrough](../../docs/deploy-a-container.md) covers private images, secrets,
persistent data and troubleshooting.
