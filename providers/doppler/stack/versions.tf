terraform {
  required_version = ">= 1.6"

  required_providers {
    doppler = {
      source  = "DopplerHQ/doppler"
      version = ">= 1.23, < 2.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
