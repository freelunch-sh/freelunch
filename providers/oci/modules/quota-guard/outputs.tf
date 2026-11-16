output "enabled" {
  description = "Whether the quota guard is on."
  value       = var.enabled
}

output "quota_id" {
  description = "OCID of the quota, or null while the guard is off."
  value       = one(oci_limits_quota.this[*].id)
}

output "statements" {
  description = "The quota statements the guard makes, from the catalogue's Always Free amounts."
  value       = local.statements
}
