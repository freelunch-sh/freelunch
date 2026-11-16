# oci/quota-guard

A budget alert reports a charge once it has happened. A **compartment quota** stops it: with this module on, OCI itself
refuses to launch any compute shape that is not Always Free, on a pay-as-you-go tenancy too.

It makes one `oci_limits_quota` in the root compartment with these statements (the amounts come from the catalogue,
`providers/oci/provider.yaml`, so they follow it when Oracle changes the allowance):

```
zero compute-core quotas in tenancy
zero compute-memory quotas in tenancy
set compute-core quota standard-a1-core-count to 2 in tenancy
set compute-memory quota standard-a1-memory-count to 12 in tenancy
set compute-core quota standard-e2-micro-core-count to 2 in tenancy
```

Statements are evaluated in order and a later one supersedes an earlier one for the same quota, so the zero is the default
and the three `set` lines are what stays allowed. Service limits still apply on top of a quota.

**Off by default** (`quota_guard = false` in the stack): it also stops you from launching a machine you meant to pay for,
and it can't be on together with `acknowledge_billable_resources`. `freelunch doctor` says whether it is on.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `tenancy_id` | string | (required) | Tenancy OCID; the quota is made in the root compartment |
| `name` | string | `freelunch` | Name prefix: the quota is `<name>-always-free-only` |
| `enabled` | bool | `false` | Make the quota |
| `allow_billable` | bool | `false` | The stack allows what is not Always Free: the guard refuses to be on |

## What is not known

Written from Oracle's own documentation (Compute Quotas, Quota Policy Syntax, Sample Quotas) and the provider's schema
(`oci_limits_quota`: `compartment_id`, `name`, `description`, `statements`), tested against a mock only. The pages do not say:

- what a launch over a quota returns (no error code or text is documented);
- whether Always Free resources count against compute quotas at all, or are exempt from them;
- whether the AMD micro shape is counted by `standard-e2-micro-core-count` (OCPUs of that shape) or by the deprecated
  shape-based `vm-standard-e2-1-micro-count`, which the module does not set.

Run it on a real pay-as-you-go tenancy and try a launch outside it before relying on it.
