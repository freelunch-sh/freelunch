terraform {
  required_version = ">= 1.6"

  required_providers {
    aiven = {
      source  = "aiven/aiven"
      version = ">= 4.0, < 5.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
