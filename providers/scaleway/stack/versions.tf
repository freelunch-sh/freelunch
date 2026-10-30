terraform {
  required_version = ">= 1.6"

  # No provider: the Serverless Containers API makes the containers, and bin/freelunch calls
  # it (see main.tf).

  # Local state by default (bin/freelunch and hybrid/ read it from here).
  # For a remote backend, see docs/architecture.md#state.
}
