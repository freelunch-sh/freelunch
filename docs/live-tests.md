# Live tests

Every test in this repository runs offline against mocks and fakes. A provider counts as
**verified live** only after someone ran freelunch against a real account and wrote down what
happened in that provider's README ("Live runs": date, commit, what ran, what failed). This page
says what a live run is and how the project keeps it safe. The [README status](../README.md)
says which providers have had one.

## What a live run does

1. `freelunch doctor`: reads the credentials and says what is missing. It changes nothing.
2. `freelunch plan <provider>`: shows what would be created. It changes nothing.
3. `freelunch apply <provider>`: creates the free-tier resources the stack describes, nothing else.
4. `freelunch deploy`, `status`, and where the provider has them `check` and `backup`.
5. `freelunch destroy <provider>`, which removes what step 3 made, then a look at the provider's
   console for leftovers.

Steps 3 to 5 run by hand on a test account, never from CI on a fork or a pull request.

## What they must not do

- Create anything outside the provider's free tier. Stacks enforce the limits with
  preconditions, and a paid shape needs an explicit `acknowledge_*` setting that a live run does
  not set.
- Use a personal account. Test accounts have their own email, organisation and billing.
- Keep credentials anywhere but the GitHub Environment named `live` (or the tester's shell).
  The environment needs the maintainer's approval for each run.
- Leave resources behind. A run ends with `destroy` and a check of the console. If it fails
  half way, the run's README entry says what is left.

## Credits

If a provider gives credits for testing, they are used only on those test accounts. A credit
account bills when the credit ends, so each test account records `credit_expires_<provider>` in
its `billing.tfvars`, which `freelunch status` and `doctor` show. Defaults and examples keep
assuming a free-tier-only account. A provider that gives credits does not get a say in what the
catalogue says about its free tier.

## The workflow

[`.github/workflows/live.yml`](../.github/workflows/live.yml) starts only by hand
(`workflow_dispatch`) in the `live` environment. It runs `doctor` for the providers whose
credentials the environment holds, and does nothing, successfully, when it holds none. It
creates nothing.

## What is still to run live

See the README status block and each provider's README. The list that matters first:

- the monitors (UptimeRobot, StatusCake), `trust` after a restart, `up --move` and `rollback`
  on a real VM;
- a deploy from GitHub Actions after an image build;
- a free domain through `domain add` and `domain status`;
- backups to a bucket with restic and a restore onto a second host.

## Budget

Free-tier only: nothing is expected to cost money. The one billed item to watch is a public
IPv4 address on GCP and Azure, which needs its own `acknowledge_*` setting.
