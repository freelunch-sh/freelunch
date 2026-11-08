# Runs offline: `terraform test` / `tofu test` from providers/motherduck/stack.
# Plans the stack against a mocked MotherDuck API.

mock_provider "motherduck" {
  mock_resource "motherduck_access_token" {
    defaults = {
      token = "mock-token"
    }
  }
}

variables {
  name_prefix = "shop"
  databases   = { main = {} }
}

run "a_database_with_a_service_account" {
  command = plan

  assert {
    condition     = motherduck_database.this["main"].name == "shop_main" && motherduck_service_account.this["main"].username == "shop_main_svc" && motherduck_access_token.this["main"].token_type == "read_write"
    error_message = "A database is <name_prefix>_<name> with a service account and a read_write token."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "motherduck" && output.databases[0].engine == "duckdb" &&
      output.databases[0].database == "shop_main" && output.databases[0].user == "shop_main_svc" &&
      output.databases[0].behavior == "always-on"
    )
    error_message = "databases should say how to attach the database, without the token."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["motherduck-main"].url) == "md:shop_main?motherduck_token=mock-token" && nonsensitive(output.database_credentials["motherduck-main"].password) == "mock-token"
    error_message = "database_credentials should hold the md: string and the token."
  }
}

run "no_service_account_means_no_credentials" {
  command = apply

  variables {
    databases = { main = { service_account = false } }
  }

  assert {
    condition     = length(nonsensitive(output.database_credentials)) == 0 && output.databases[0].user == ""
    error_message = "Without a service account there is no token to output."
  }
}

run "three_service_accounts_need_an_acknowledgement" {
  command = plan

  variables {
    databases = { a = {}, b = {}, c = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_three_service_accounts_plan" {
  command = plan

  variables {
    databases                      = { a = {}, b = {}, c = {} }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(motherduck_service_account.this) == 3
    error_message = "With the acknowledgement three service accounts should plan."
  }
}
