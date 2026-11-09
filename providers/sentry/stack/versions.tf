terraform {
  required_version = ">= 1.6"

  required_providers {
    sentry = {
      source  = "jianyuan/sentry"
      version = ">= 0.15, < 1.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
