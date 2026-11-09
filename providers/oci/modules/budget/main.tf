# A monthly budget over the whole tenancy, with an email when actual spend reaches the amount
# and, optionally, when OCI forecasts it will. Always Free costs $0, so any alert means
# something is billed.
locals {
  enabled = length(var.alert_emails) > 0
}

resource "oci_budget_budget" "this" {
  count = local.enabled ? 1 : 0

  compartment_id = var.tenancy_id
  display_name   = "${var.name}-budget"
  description    = "freelunch: alert as soon as anything is billed"
  amount         = var.amount
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_id]
}

resource "oci_budget_alert_rule" "actual" {
  count = local.enabled ? 1 : 0

  budget_id      = oci_budget_budget.this[0].id
  display_name   = "${var.name}-actual-spend"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = join(",", var.alert_emails)
  message        = "freelunch: spend reached the ${var.amount} budget. Always Free resources cost nothing, so something is billed: check the Cost Analysis page and the instances in the tenancy."
}

resource "oci_budget_alert_rule" "forecast" {
  count = local.enabled && var.forecast_threshold_percent > 0 ? 1 : 0

  budget_id      = oci_budget_budget.this[0].id
  display_name   = "${var.name}-forecast-spend"
  type           = "FORECAST"
  threshold      = var.forecast_threshold_percent
  threshold_type = "PERCENTAGE"
  recipients     = join(",", var.alert_emails)
  message        = "freelunch: OCI forecasts this month's spend will reach ${var.forecast_threshold_percent}% of the ${var.amount} budget."
}
