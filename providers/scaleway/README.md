# Scaleway Serverless Containers

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Containers & PaaS |
| **Layer** | `platform`: runs your apps' images without a VM; deploy goes through its API |
| **Free tier** | ♾️ Always free (within limits) |
| **Card required** | yes |
| **Terraform provider** | None needed: freelunch talks to the [Serverless Containers API](https://www.scaleway.com/en/developers/api/serverless-containers/) |
| **Last verified** | 2026-10-30 |

## What's free

Per account and month: **400,000 GB-seconds** of memory and **200,000 vCPU-seconds**. That is
the one free thing here that can stay on: Scaleway's smallest container (128 MB, 70 mVCPU)
uses about 329,000 GB-s and 184,000 vCPU-s in a month that it never stops. Bigger ones fit
when they scale to zero between requests.

The stack checks this: `min_scale = 1` with more than 128 MB fails the plan unless you set
`acknowledge_billable_resources = true`. Beyond the grant Scaleway bills about EUR 0.000002
per GB-s and EUR 0.00001 per vCPU-s. Free tiers change, so check the
[pricing page](https://www.scaleway.com/en/pricing/serverless/).

## API key

Create an API key (console > IAM > API keys) for a user or application that can manage
Serverless Containers in the project, and put its secret key in `.freelunch/.env`:

```bash
SCW_SECRET_KEY=...
# SCW_SECRET_KEY=op://Private/Scaleway/secret-key
```

## Usage

```bash
freelunch init scaleway
cp .freelunch/scaleway/terraform.tfvars.example .freelunch/scaleway/terraform.tfvars   # set project_id
freelunch apply scaleway      # the container namespace
freelunch deploy              # a container per app, then waits until each one is ready
```

The target is `scaleway-main`; point an app at it in `.freelunch/apps.tfvars`.

## What carries over from the Compose file

The image (pinned to its digest), `entrypoint` and `command`, `environment` and the app's
`env_file` (all as secret variables, which Scaleway doesn't show again), a bucket from
`apps.tfvars`, and the first port. Containers are public at the HTTPS URL Scaleway gives them.

## What doesn't

- No Cloudflare Tunnel, no volumes and no healthcheck command, as on [Cloud Run](../cloud-run/).
- Cold starts when a container has scaled to zero.
- Scaleway pulls public images from Docker Hub and GHCR itself, but can't log in to another
  private registry, so an image from a registry listed under `registries` in `apps.tfvars`
  is copied first (see below).
- The memory and CPU pairs in the stack (128 MB with 70 mVCPU and so on) come from
  Scaleway's SDK; the pricing page's table of valid pairs hasn't been checked.
- That `deploy` can update a container's secret variables with PATCH, as it does with
  POST, isn't confirmed either.

## Private images

An image from a registry with a login in `apps.tfvars` is private. `deploy` logs in with it,
pulls the image for `linux/amd64`, and pushes it to a private Container Registry namespace
named like the project (`rg.<region>.scw.cloud/<name_prefix>`), which it makes when missing.
The container runs that copy by digest, so the image never becomes public. This needs
Docker on the machine that runs `deploy`, and `destroy` deletes the namespace with its
images. Registry names are shared in a region, so a name someone else has stops the deploy:
pick another `name_prefix`. Docker logs in with a config of its own that is deleted
afterwards. Not yet run against a real account.

## References

- scaleway.com/en/pricing/serverless (free grant)
- github.com/scaleway/scaleway-sdk-go (api/container/v1: the request and response fields)
