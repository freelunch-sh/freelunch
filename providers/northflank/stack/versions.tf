terraform {
  required_version = ">= 1.6"

  # No provider: Northflank has no Terraform provider for projects and services, so
  # bin/freelunch talks to its API (see main.tf).

  # Local state by default (bin/freelunch and hybrid/ read it from here).
  # For a remote backend, see docs/architecture.md#state.
}
