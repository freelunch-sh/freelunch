# Bitbucket Pipelines

| | |
|---|---|
| **Status** | ✅ Pipeline written from a template (not yet run on a real account) |
| **Category** | IaC state, CI & registries |
| **Engine** | `ci` (`freelunch ci init bitbucket` writes bitbucket-pipelines.yml) |
| **Free tier** | 50 build minutes a month for a free workspace |
| **Card required** | no |

```bash
freelunch ci init bitbucket                    # writes bitbucket-pipelines.yml
freelunch ci secrets --print            # the bundle: what CI needs and git doesn't have
```

1. Put the bundle in the CI's secret **FREELUNCH_BUNDLE**: Repository settings > Pipelines > Repository variables, secured.
2. Commit and push the pipeline, and run it: Pipelines > Run pipeline > Custom: freelunch.

The pipeline runs freelunch's runner image (`ghcr.io/freelunch-sh/freelunch`, pinned like the project),
restores the bundle and runs the command. It never runs on a push: a deploy from CI is something you
start, or schedule. It is a `custom` pipeline, so it runs only by hand or on a schedule. It needs the state in a store both this machine and CI reach
(`freelunch state init`), as [docs/ci.md](../../docs/ci.md) explains. The template is
`pipeline.tpl` here; `@IMAGE@` is the only placeholder.

Build minutes are shared across the workspace.
