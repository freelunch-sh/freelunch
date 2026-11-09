# Codeberg (Forgejo Actions)

| | |
|---|---|
| **Status** | ✅ Pipeline written from a template (not yet run on a real account) |
| **Category** | IaC state, CI & registries |
| **Engine** | `ci` (`freelunch ci init codeberg` writes .forgejo/workflows/freelunch.yml) |
| **Free tier** | Forgejo hosting for free/libre projects, with Actions runners |
| **Card required** | no |

```bash
freelunch ci init codeberg                    # writes .forgejo/workflows/freelunch.yml
freelunch ci secrets --print            # the bundle: what CI needs and git doesn't have
```

1. Put the bundle in the CI's secret **FREELUNCH_BUNDLE**: Repository Settings > Actions > Secrets.
2. Commit and push the pipeline, and run it: Actions > freelunch > Run workflow.

The pipeline runs freelunch's runner image (`ghcr.io/freelunch-sh/freelunch`, pinned like the project),
restores the bundle and runs the command. It never runs on a push: a deploy from CI is something you
start, or schedule. It is `workflow_dispatch` only. It needs the state in a store both this machine and CI reach
(`freelunch state init`), as [docs/ci.md](../../docs/ci.md) explains. The template is
`pipeline.tpl` here; `@IMAGE@` is the only placeholder.

Codeberg is for projects under a free/libre licence. The template uses the runner label `docker` and fetches the checkout action from code.forgejo.org; check both against Codeberg's current Actions documentation.
