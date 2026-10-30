terraform {
  required_version = ">= 1.6"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 9.0, < 10.0"
    }
  }

  # Local state by default (bin/freelunch reads it from here).
  # For a remote backend, see docs/architecture.md#state.
}
