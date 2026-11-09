# Docker Hub

| | |
|---|---|
| **Status** | ✅ Image workflow written (not yet run on a real account) |
| **Category** | IaC state, CI & registries |
| **Engine** | `registry` (where `freelunch init --image-workflow --registry docker-hub` pushes) |
| **Free tier** | 1 private repository, unlimited public ones |
| **Card required** | no |

A container registry for your app's image. freelunch makes no repository: Docker Hub makes one on
the first push.

```bash
freelunch init --image-workflow --registry docker-hub              # docker.io/<you>/<repo>
freelunch init --image-workflow --registry docker-hub --registry-image docker.io/acme/shop
```

The workflow logs in with two Actions secrets of the repository, `DOCKERHUB_USERNAME` and
`DOCKERHUB_TOKEN` (Account Settings > Personal access tokens, read and write). For a private
repository, deploy needs a **read-only** token of its own under `registries` in `apps.tfvars`:

```hcl
registries = {
  "docker.io" = { username = "acme", password_env = "DOCKERHUB_READ_TOKEN" }
}
```

Docker Hub rate-limits anonymous pulls, so a host that pulls often benefits from this login even for
public images. An image on Docker Hub is `docker.io/<you>/<repo>` in a Compose file, or just `<you>/<repo>`.
