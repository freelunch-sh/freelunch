terraform {
  required_version = ">= 1.6"

  required_providers {
    axiom = {
      source  = "axiomhq/axiom"
      version = ">= 1.9, < 2.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
