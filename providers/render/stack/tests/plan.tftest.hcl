# Runs offline: `terraform test` / `tofu test` from providers/render/stack.

variables {
  owner_id    = "usr-abc123def456"
  name_prefix = "sunbird"
}

run "free_target_plans" {
  command = plan

  assert {
    condition     = output.platforms[0].provider == "render" && output.platforms[0].id == "sunbird" && output.platforms[0].settings.owner_id == "usr-abc123def456"
    error_message = "The target should be the workspace, named by name_prefix."
  }

  assert {
    condition     = output.platforms[0].tunnel == false && output.platforms[0].size == "free" && output.platforms[0].region == "oregon"
    error_message = "Render has no tunnel; the default plan is free in oregon."
  }
}

run "paid_plan_needs_an_acknowledgement" {
  command = plan

  variables {
    plan = "starter"
  }

  expect_failures = [terraform_data.target]
}

run "acknowledged_paid_plan_plans" {
  command = plan

  variables {
    plan                           = "starter"
    acknowledge_billable_resources = true
  }

  assert {
    condition     = output.platforms[0].size == "starter"
    error_message = "With the acknowledgement a paid plan should plan."
  }
}

run "bad_owner_id_is_rejected" {
  command = plan

  variables {
    owner_id = "abc123"
  }

  expect_failures = [var.owner_id]
}

run "bad_region_is_rejected" {
  command = plan

  variables {
    region = "mars"
  }

  expect_failures = [var.region]
}
