# Buildkite

| | |
|---|---|
| **Status** | ✅ Pipeline written from a template (not yet run on a real account) |
| **Category** | IaC state, CI & registries |
| **Engine** | `ci` (`freelunch ci init buildkite` writes .buildkite/pipeline.yml) |
| **Free tier** | 5 users, 2,000 hosted Linux vCPU-minutes a month |
| **Card required** | no |

```bash
freelunch ci init buildkite                    # writes .buildkite/pipeline.yml
freelunch ci secrets --print            # the bundle: what CI needs and git doesn't have
```

1. Put the bundle in the CI's secret **FREELUNCH_BUNDLE**: Pipeline settings > Environment Variables.
2. Commit and push the pipeline, and run it: New Build, with `FREELUNCH_RUN` in its environment (default `up`).

The pipeline runs freelunch's runner image (`ghcr.io/freelunch-sh/freelunch`, pinned like the project),
restores the bundle and runs the command. It never runs on a push: a deploy from CI is something you
start, or schedule. Add a schedule for a wait. It needs the state in a store both this machine and CI reach
(`freelunch state init`), as [docs/ci.md](../../docs/ci.md) explains. The template is
`pipeline.tpl` here; `@IMAGE@` is the only placeholder.

The step uses the `docker` plugin (pinned to v5.11.0 in the template; check it is the version you want), so the agent needs Docker. Self-hosted agents can run on free hosts from the hybrid inventory.
