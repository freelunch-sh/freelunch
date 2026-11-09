# Runs offline: `terraform test` / `tofu test` from providers/oci/modules/budget.

mock_provider "oci" {}

variables {
  tenancy_id = "ocid1.tenancy.oc1..mock"
}

run "no_email_no_budget" {
  command = plan

  assert {
    condition     = output.enabled == false && length(oci_budget_budget.this) == 0
    error_message = "Without a recipient there is nothing to alert, so no budget is made."
  }
}

run "email_creates_budget_and_both_alerts" {
  command = plan

  variables {
    alert_emails = ["me@example.com", "you@example.com"]
  }

  assert {
    condition     = oci_budget_budget.this[0].amount == 1 && oci_budget_budget.this[0].reset_period == "MONTHLY" && oci_budget_budget.this[0].targets == tolist(["ocid1.tenancy.oc1..mock"])
    error_message = "A $1 monthly budget over the tenancy."
  }

  assert {
    condition     = oci_budget_alert_rule.actual[0].recipients == "me@example.com,you@example.com" && oci_budget_alert_rule.actual[0].type == "ACTUAL" && oci_budget_alert_rule.forecast[0].type == "FORECAST"
    error_message = "Actual and forecast rules email every recipient."
  }
}

run "forecast_can_be_turned_off" {
  command = plan

  variables {
    alert_emails               = ["me@example.com"]
    forecast_threshold_percent = 0
  }

  assert {
    condition     = length(oci_budget_alert_rule.forecast) == 0 && length(oci_budget_alert_rule.actual) == 1
    error_message = "forecast_threshold_percent = 0 leaves only the actual-spend rule."
  }
}
