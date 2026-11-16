# Watching for what the free tier changes

A free tier is a promise a company can change. Oracle halved its free Arm allowance in mid-2026 with little notice, several
free platforms put apps to sleep, and a trial credit ends on a date. `freelunch watch` looks for these, and for the signs
that something already costs money:

```bash
freelunch watch              # check lines; exit 0
freelunch watch --strict     # exit 1 while anything is wrong
freelunch watch --json       # [{ level, check, message }]
```

| Check | What it says |
|---|---|
| free tier | for each provider the project uses, a line for every field of its `provider.yaml` (`free_tier`, `free_tier_type`, `card_required`, `status`, `notes`) that the newest release of freelunch records differently, and whether the project's tfvars are over a changed `limits` value (OCI's Arm OCPUs). Without a network it says it couldn't check, and goes on |
| expiry | what expires within 30 days: service tokens, the free-trial credits and free domains of `.freelunch/billing.tfvars` (`credit_expires_<provider>`, `domain_expires_<name with dots as underscores>`), an OCI session a wait signs in with |
| backups | an app whose last backup failed or is older than twice its schedule |
| disk | a host at 85% or more |
| bill | OCI's bill this month above zero, and over `spend_cap_usd` when one is set |
| idle | on an Always Free tenancy, a machine whose week of CPU (p95) is under the catalogue's idle rule (`limits.compute.idle`, 20% over 7 days for OCI): "Oracle may reclaim it as idle". It is a warning with no remedy offered: freelunch does not help keep a machine busy to get round the rule |

It tells `FREELUNCH_NOTIFY` (the `watch` event, see [Notifications](ci.md#notifications)) only what is **new** since its last
run: the last result is in `.freelunch/watch.state`, and what cleared is told once.

## Every week, from CI

`freelunch ci init --jobs=watch` writes `.github/workflows/freelunch-watch.yml`: a weekly run (Monday, 06:17 UTC) and a
button, which runs `freelunch watch` with the secrets the project's other workflows use, and puts what it finds in the run's
summary. `freelunch ci init --pipeline` writes it with the pipeline. The run reads and changes nothing; `freelunch ci needs`
names any secret it lacks. A run in CI starts without the last run's state, so it tells everything it finds each week.

## What it does not do

A budget alert (`budget_alert_emails` on OCI, the budgets of the other clouds) reports a charge after it happens; it does not
stop one. `watch` finds a bill the same way, after the fact. Nothing in this list prevents a charge on a pay-as-you-go
account, except quotas that forbid what is not free (see `doctor`, and the quota guard when it exists).
