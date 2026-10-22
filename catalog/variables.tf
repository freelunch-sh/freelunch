variable "providers_dir" {
  description = "Directory containing <name>/provider.yaml files. null means ../providers (used by tests to point at fixtures)."
  type        = string
  default     = null
}
