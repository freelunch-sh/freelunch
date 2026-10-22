terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0, < 9.0"
    }
  }

  # Local state by default (bin/freelunch and hybrid/ read it from here).
  # For a remote backend, see docs/architecture.md#state.
}
