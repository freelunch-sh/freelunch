terraform {
  required_version = ">= 1.6"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0, < 4.0"
    }

    couchbase-capella = {
      source  = "couchbasecloud/couchbase-capella"
      version = ">= 1.0, < 2.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
