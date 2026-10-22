terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }

  # Local state by default (bin/freelunch and hybrid/ read it from here).
  # For a remote backend, see docs/architecture.md#state.
}
