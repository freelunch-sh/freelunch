terraform {
  required_version = ">= 1.6"

  required_providers {
    gcore = {
      source  = "G-Core/gcore"
      version = ">= 0.37, < 1.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
