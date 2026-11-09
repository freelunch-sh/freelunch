terraform {
  required_version = ">= 1.6"

  required_providers {
    netbird = {
      source  = "netbirdio/netbird"
      version = ">= 0.0.11, < 1.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
