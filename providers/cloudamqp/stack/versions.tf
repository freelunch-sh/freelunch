terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudamqp = {
      source  = "cloudamqp/cloudamqp"
      version = ">= 1.52, < 2.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
