terraform {
  required_version = ">= 1.6"

  required_providers {
    neo4jaura = {
      source  = "neo4j-labs/neo4jaura"
      version = ">= 1.1, < 2.0"
    }
  }

  # Local state by default (bin/freelunch passes the project's state file).
  # For a remote backend, see docs/architecture.md#state.
}
