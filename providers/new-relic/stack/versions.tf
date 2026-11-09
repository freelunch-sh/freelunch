terraform {
  required_version = ">= 1.6"

  required_providers {
    newrelic = {
      source  = "newrelic/newrelic"
      version = ">= 3.101, < 4.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
