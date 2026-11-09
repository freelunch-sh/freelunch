# oci/budget

A monthly budget over the whole tenancy and an email alert, so the safety net exists before
the first VM. Always Free costs $0, so an alert at $1 means something is billed.

Creates `oci_budget_budget` (target: the tenancy) and an `ACTUAL` alert rule at 100% of the
amount, plus a `FORECAST` rule. Budgets are always created in the root compartment.

An alert rule needs a recipient, so **no `alert_emails` means no budget**; `freelunch doctor`
and `freelunch plan` say so.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `tenancy_id` | string | (required) | Tenancy OCID |
| `name` | string | `freelunch` | Name prefix |
| `amount` | number | `1` | Monthly budget |
| `alert_emails` | list(string) | `[]` | Recipients |
| `forecast_threshold_percent` | number | `100` | Forecast alert threshold; `0` turns it off |

## Outputs

`budget_id`, `enabled`.
