# Runs offline: `terraform test` / `tofu test` from providers/supabase/stack.
# Plans the stack against a mocked Supabase API.

mock_provider "supabase" {
  mock_resource "supabase_project" {
    defaults = { id = "abcdefghijklmnopqrst" }
  }
}

mock_provider "random" {
  mock_resource "random_password" {
    defaults = { result = "mockpassword0123456789mockpassword" }
  }
}

variables {
  name_prefix     = "shop"
  organization_id = "my-org"
  databases       = { main = {} }
}

run "a_project_named_after_the_database" {
  command = plan

  assert {
    condition     = supabase_project.this["main"].name == "shop-main" && supabase_project.this["main"].region == "us-east-1"
    error_message = "A project is <name_prefix>-<name>, in us-east-1 by default."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "supabase" && output.databases[0].host == "db.abcdefghijklmnopqrst.supabase.co" &&
      output.databases[0].behavior == "pauses" && output.databases[0].port == 5432
    )
    error_message = "databases should say where the project is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["supabase-main"].url) == "postgresql://postgres:mockpassword0123456789mockpassword@db.abcdefghijklmnopqrst.supabase.co:5432/postgres"
    error_message = "database_credentials should hold the connection string."
  }
}

run "a_third_project_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { a = {}, b = {}, c = {} }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_third_project_plans" {
  command = plan

  variables {
    databases                      = { a = {}, b = {}, c = {} }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(supabase_project.this) == 3
    error_message = "With the acknowledgement three projects should plan."
  }
}
