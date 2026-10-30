# Google Cloud Run

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real account) |
| **Category** | Containers & PaaS |
| **Layer** | `platform`: runs your apps' images without a VM; deploy goes through its API |
| **Free tier** | ♾️ Always free (within limits) |
| **Card required** | yes |
| **Terraform provider** | None needed: freelunch talks to the [Cloud Run Admin API](https://cloud.google.com/run/docs/reference/rest) |
| **Last verified** | 2026-10-30 |

Cloud Run starts your container when a request arrives and stops it between requests, so
the free grant is spent only while the app answers. It suits an API or a site with bursty
traffic, not a worker that has to stay up. Each app gets an HTTPS `run.app` URL.

## What's free

Per billing account and month, with request-based billing:

| Resource | Free grant | What it comes to |
|---|---|---|
| Requests | 2 million | |
| CPU | 180,000 vCPU-seconds | 50 hours of one vCPU serving requests |
| Memory | 360,000 GiB-seconds | 100 hours of 1 GiB, or 200 hours of 512 MiB |
| Artifact Registry | 0.5 GB | only if you keep images there |

freelunch keeps the services inside this: no minimum instances, CPU only while a request is
served, and one instance at most (`max_instances`). Free tiers change, so check the
[pricing page](https://cloud.google.com/run/pricing).

## Sign in

freelunch takes a Google access token from `CLOUD_RUN_ACCESS_TOKEN`, or else from
`gcloud auth application-default print-access-token`, or `gcloud auth print-access-token`.
The simplest is:

```bash
gcloud auth application-default login
```

The account needs to create and delete Cloud Run services in the project (the Cloud Run
Admin role), and `apply cloud-run` turns the Cloud Run API on when it is off, which needs
the Service Usage Admin role. The project needs a billing account.

## Usage

```bash
freelunch init cloud-run
cp .freelunch/cloud-run/terraform.tfvars.example .freelunch/cloud-run/terraform.tfvars   # set project_id
freelunch apply cloud-run     # checks the project and turns the API on
freelunch deploy              # a service per app, then waits until each one serves
```

The target is `cloud-run-main`; point an app at it in `.freelunch/apps.tfvars`:

```hcl
apps = {
  api = { host = "cloud-run-main", compose = "../compose.yaml", env_file = "api.env" }
}
```

## What carries over from the Compose file

The image (pinned to the digest its tag points to), `entrypoint` and `command`,
`environment` and the app's `env_file`, a bucket from `apps.tfvars`, and the first port of
`ports` or `expose`, which Cloud Run sends requests to. Each service is public
(`invokerIamDisabled`) and labelled `freelunch=managed` and `freelunch-project=<name_prefix>`,
which `status` and `destroy` go by; freelunch leaves other services alone.

## What doesn't

- **No Cloudflare Tunnel.** An instance that scales to zero can't hold a tunnel open, and
  Cloudflare's free plan can't rewrite the Host header a `run.app` URL needs (Origin Rules do
  that on Enterprise only). Use the `run.app` URL, put a Worker in front of it (100,000
  requests a day free), or map your own domain in Cloud Run.
- **No volumes.** The disk is gone when the instance stops. Keep data in a bucket
  (`bucket` in `apps.tfvars`) or a managed database; deploy stops on a named volume.
- **Only Google's registries.** Cloud Run pulls from Artifact Registry (and `gcr.io`), not
  from GHCR or Docker Hub, and it can't log in to another registry. So `deploy` copies every
  other image, public or private, into a private Artifact Registry repository named like the
  project, makes the repository when missing, and runs the copy by digest. See below.
- **No healthcheck command.** Cloud Run waits for the container to listen on its port.
- **Cold starts.** The first request after a quiet spell waits for the container to start.

## Images

An image that is already in Artifact Registry or `gcr.io` in the same project is deployed as
it is. Any other is copied: `deploy` logs in to the source with its `registries` entry in
`apps.tfvars` (none for a public image), pulls it for `linux/amd64`, and pushes it to
`<region>-docker.pkg.dev/<project>/<name_prefix>/<app>`. A private image never becomes
public. This needs Docker on the machine that runs `deploy`, and the copy counts against the
0.5 GB of free Artifact Registry storage; old copies stay until `destroy` deletes the
repository. Docker logs in with a config of its own that is deleted afterwards. Not yet run
against a real account.

## References

- cloud.google.com/run/pricing, docs.cloud.google.com/free/docs/free-cloud-features (free grant)
- cloud.google.com/run/docs/reference/rest/v2/projects.locations.services (the service body)
- cloud.google.com/run/docs/deploying (which registries Cloud Run pulls from)
- developers.cloudflare.com/rules/origin-rules (Host header overrides are Enterprise only)
