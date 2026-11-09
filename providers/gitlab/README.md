# GitLab

| | |
|---|---|
| **Status** | ✅ Built into the CLI (not run on a real account by the tests) |
| **Category** | IaC state, CI & registries |
| **Engine** | `ci` (built in) |
| **Free tier** | Unlimited repos with up to 5 collaborators; CI/CD minutes, Pages, container registry |
| **Card required** | no |

`freelunch ci init gitlab` writes `.gitlab-ci.yml` (or `.gitlab/freelunch.yml` beside an existing one),
which runs freelunch's runner image with the bundle in the CI variable `FREELUNCH_BUNDLE`. GitLab can hold
the project's state too (`freelunch state init gitlab`, its own state for the project, reached with the job's
token). Its container registry is `registry.gitlab.com`; give `freelunch init --image-workflow --registry gitlab
--registry-image registry.gitlab.com/<group>/<project>` to push there from a GitHub workflow, or build in
GitLab's own CI. See [docs/ci.md](../../docs/ci.md#gitlab-ci).
