# Runs offline: `terraform test` / `tofu test` from providers/datastax-astra/stack.
# Plans the stack against a mocked Astra API.

mock_provider "astra" {
  mock_resource "astra_database" {
    defaults = {
      data_endpoint_url = "https://0123abcd-us-east1.apps.astra.datastax.com/api/rest"
    }
  }
  mock_resource "astra_token" {
    defaults = {
      token = "AstraCS:mock-token"
    }
  }
}

variables {
  name_prefix = "shop"
  databases   = { main = {} }
}

run "a_database_named_after_the_entry" {
  command = plan

  assert {
    condition     = astra_database.this["main"].name == "shop-main" && astra_database.this["main"].keyspace == "app" && astra_database.this["main"].cloud_provider == "gcp"
    error_message = "A database is <name_prefix>-<name> with a keyspace called app."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "datastax-astra" && output.databases[0].host == "0123abcd-us-east1.apps.astra.datastax.com" &&
      output.databases[0].port == 443 && output.databases[0].behavior == "pauses"
    )
    error_message = "databases should say where the database is, without the token."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["datastax-astra-main"].password) == "" && nonsensitive(output.database_credentials["datastax-astra-main"].url) == "https://0123abcd-us-east1.apps.astra.datastax.com/api/rest"
    error_message = "Without token_role_ids the password is empty and url is the Data API endpoint."
  }
}

run "a_token_lands_in_the_credentials" {
  command = apply

  variables {
    token_role_ids = ["role-1"]
  }

  assert {
    condition     = nonsensitive(output.database_credentials["datastax-astra-main"].password) == "AstraCS:mock-token"
    error_message = "With token_role_ids the application token is the password."
  }
}

run "a_sixth_database_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { for i in range(6) : "db${i}" => {} }
  }

  expect_failures = [terraform_data.checks]
}

run "unknown_cloud_is_rejected" {
  command = plan

  variables {
    databases = { main = { cloud_provider = "oracle" } }
  }

  expect_failures = [terraform_data.checks]
}
