# Runs offline: `terraform test` / `tofu test` from providers/northflank/stack.
# The stack has no provider, so there is nothing to mock.

run "free_sandbox_by_default" {
  command = plan

  assert {
    condition = output.platforms[0] == {
      provider     = "northflank"
      name         = "main"
      id           = "freelunch"
      region       = "europe-west"
      arch         = "amd64"
      size         = "nf-compute-20"
      tunnel       = true
      max_services = 2
    }
    error_message = "The default target is one Northflank project on the biggest free plan, with two services."
  }
}

run "the_project_is_named_after_the_project" {
  command = plan

  variables {
    name_prefix = "moneyspider"
    region      = "us-central"
  }

  assert {
    condition     = output.platforms[0].id == "moneyspider" && terraform_data.project.input.region == "us-central"
    error_message = "name_prefix is the Northflank project's ID."
  }
}

run "plans_outside_the_sandbox_fail" {
  command = plan

  variables {
    plan = "nf-compute-50"
  }

  expect_failures = [terraform_data.project]
}

run "acknowledged_plans_lift_the_limits" {
  command = plan

  variables {
    plan                           = "nf-compute-50"
    acknowledge_billable_resources = true
  }

  assert {
    condition     = output.platforms[0].size == "nf-compute-50" && output.platforms[0].max_services == null
    error_message = "With acknowledge_billable_resources, any plan and any number of services are allowed."
  }
}

run "names_northflank_refuses_fail" {
  command = plan

  variables {
    name_prefix = "ab"
  }

  expect_failures = [var.name_prefix]
}
