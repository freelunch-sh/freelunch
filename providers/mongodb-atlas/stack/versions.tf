terraform {
  required_version = ">= 1.6"

  required_providers {
    mongodbatlas = {
      source  = "mongodb/mongodbatlas"
      version = ">= 2.0, < 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5, < 4.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
