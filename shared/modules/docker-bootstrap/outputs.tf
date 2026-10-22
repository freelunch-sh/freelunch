output "user_data" {
  description = "Rendered #cloud-config document (plain text)."
  value       = local.user_data
  sensitive   = true

  precondition {
    condition     = var.max_encoded_size_bytes == null || length(base64encode(local.user_data)) <= coalesce(var.max_encoded_size_bytes, 0)
    error_message = "Rendered cloud-init exceeds the provider's user data limit. Move large compose files out of user data (e.g. pull them from git on boot)."
  }
}

output "user_data_base64" {
  description = "Rendered #cloud-config document, base64-encoded."
  value       = base64encode(local.user_data)
  sensitive   = true
}
