terraform {
  required_version = ">= 1.6"

  required_providers {
    ybm = {
      source  = "yugabyte/ybm"
      version = ">= 1.0, < 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
