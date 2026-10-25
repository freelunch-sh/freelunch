terraform {
  required_version = ">= 1.6"

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = ">= 0.12, < 1.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
