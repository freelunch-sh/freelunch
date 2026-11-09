# Runs offline: `terraform test` / `tofu test` from providers/neon/stack.
# Plans the stack against a mocked Neon API.

mock_provider "neon" {
  mock_resource "neon_project" {
    defaults = {
      database_host     = "ep-cool-darkness-123456.us-east-2.aws.neon.tech"
      database_name     = "app"
      database_user     = "app"
      database_password = "mock-password"
      connection_uri    = "postgresql://app:mock-password@ep-cool-darkness-123456.us-east-2.aws.neon.tech/app?sslmode=require"
    }
  }
}

variables {
  name_prefix = "shop"
  databases   = { main = {} }
}

run "a_project_named_after_the_database" {
  command = plan

  assert {
    condition     = neon_project.this["main"].name == "shop-main" && neon_project.this["main"].pg_version == 17 && neon_project.this["main"].autoscaling_limit_max_cu == 2
    error_message = "A project is <name_prefix>-<name> on Postgres 17, capped at 2 compute units."
  }
}

run "outputs_follow_the_database_contract" {
  command = apply

  assert {
    condition = (
      output.databases[0].provider == "neon" && output.databases[0].engine == "postgres" &&
      output.databases[0].host == "ep-cool-darkness-123456.us-east-2.aws.neon.tech" && output.databases[0].behavior == "scale-to-zero"
    )
    error_message = "databases should say where the project is, without the password."
  }

  assert {
    condition     = nonsensitive(output.database_credentials["neon-main"].url) == "postgresql://app:mock-password@ep-cool-darkness-123456.us-east-2.aws.neon.tech/app?sslmode=require"
    error_message = "database_credentials should hold the connection string."
  }
}

run "more_compute_than_the_free_plan_needs_an_acknowledgement" {
  command = plan

  variables {
    databases = { main = { max_cu = 4 } }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_compute_plans" {
  command = plan

  variables {
    databases                      = { main = { max_cu = 4 } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = neon_project.this["main"].autoscaling_limit_max_cu == 4
    error_message = "With the acknowledgement 4 compute units should plan."
  }
}

run "more_than_100_projects_need_an_acknowledgement" {
  command = plan

  variables {
    databases = { for i in range(101) : "db${i}" => {} }
  }

  expect_failures = [terraform_data.checks]
}

run "unknown_postgres_version_is_rejected" {
  command = plan

  variables {
    databases = { main = { pg_version = 9 } }
  }

  expect_failures = [terraform_data.checks]
}
