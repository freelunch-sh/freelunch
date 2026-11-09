# Azure DevOps

| | |
|---|---|
| **Status** | ✅ Pipeline written from a template (not yet run on a real account) |
| **Category** | IaC state, CI & registries |
| **Engine** | `ci` (`freelunch ci init azure-devops` writes azure-pipelines.yml) |
| **Free tier** | 5 basic users, 1,800 Microsoft-hosted minutes a month |
| **Card required** | no |

```bash
freelunch ci init azure-devops                    # writes azure-pipelines.yml
freelunch ci secrets --print            # the bundle: what CI needs and git doesn't have
```

1. Put the bundle in the CI's secret **FREELUNCH_BUNDLE**: the pipeline's Variables, kept secret.
2. Commit and push the pipeline, and run it: Run pipeline, and choose the command.

The pipeline runs freelunch's runner image (`ghcr.io/freelunch-sh/freelunch`, pinned like the project),
restores the bundle and runs the command. It never runs on a push: a deploy from CI is something you
start, or schedule. It has `trigger: none` and `pr: none`. It needs the state in a store both this machine and CI reach
(`freelunch state init`), as [docs/ci.md](../../docs/ci.md) explains. The template is
`pipeline.tpl` here; `@IMAGE@` is the only placeholder.

New organisations may have to ask for the free Microsoft-hosted parallel job before a pipeline runs. A secret variable reaches a step only through `env:`, as the template does.
