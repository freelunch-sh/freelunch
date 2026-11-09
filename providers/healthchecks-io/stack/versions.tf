terraform {
  required_version = ">= 1.6"

  required_providers {
    healthchecksio = {
      source  = "kristofferahl/healthchecksio"
      version = ">= 2.3, < 3.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
