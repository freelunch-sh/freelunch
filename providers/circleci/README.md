# CircleCI

| | |
|---|---|
| **Status** | ✅ Pipeline written from a template (not yet run on a real account) |
| **Category** | IaC state, CI & registries |
| **Engine** | `ci` (`freelunch ci init circleci` writes .circleci/config.yml) |
| **Free tier** | 30,000 credits a month, 5 active users |
| **Card required** | no |

```bash
freelunch ci init circleci                    # writes .circleci/config.yml
freelunch ci secrets --print            # the bundle: what CI needs and git doesn't have
```

1. Put the bundle in the CI's secret **FREELUNCH_BUNDLE**: Project Settings > Environment Variables.
2. Commit and push the pipeline, and run it: Trigger Pipeline (or the API) with the parameter `freelunch-run`.

The pipeline runs freelunch's runner image (`ghcr.io/freelunch-sh/freelunch`, pinned like the project),
restores the bundle and runs the command. It never runs on a push: a deploy from CI is something you
start, or schedule. A pipeline only runs when triggered through the API or a schedule. It needs the state in a store both this machine and CI reach
(`freelunch state init`), as [docs/ci.md](../../docs/ci.md) explains. The template is
`pipeline.tpl` here; `@IMAGE@` is the only placeholder.

Credits expire monthly, and a medium resource class uses them twice as fast as small. The job runs on the default Docker executor.
