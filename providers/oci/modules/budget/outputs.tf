output "budget_id" {
  description = "OCID of the budget, or null when no alert_emails were given."
  value       = one(oci_budget_budget.this[*].id)
}

output "enabled" {
  description = "Whether a budget alert exists."
  value       = local.enabled
}
