# Runs offline: `terraform test` / `tofu test` from providers/scaleway/stack.
# The stack has no provider, so there is nothing to mock.

variables {
  project_id = "11111111-2222-3333-4444-555555555555"
}

run "scale_to_zero_by_default" {
  command = plan

  assert {
    condition = output.platforms[0] == {
      provider     = "scaleway"
      name         = "main"
      id           = "freelunch"
      region       = "fr-par"
      arch         = "amd64"
      size         = "128 MB, 70 mVCPU"
      tunnel       = false
      max_services = null
      volume_size  = null
      pricing      = { budget = null, service = null, tunnel = null, volume_gb = null }
      settings     = { project_id = "11111111-2222-3333-4444-555555555555", memory_mb = 128, mvcpu = 70, min_scale = 0, max_scale = 1 }
    }
    error_message = "The default target is a 128 MB container that scales to zero, with no tunnel and no volumes."
  }
}

run "one_small_container_can_stay_on" {
  command = plan

  variables {
    min_scale = 1
  }

  assert {
    condition     = output.platforms[0].settings.min_scale == 1
    error_message = "A 128 MB container fits the free grant all month."
  }
}

run "a_bigger_container_cannot_stay_on" {
  command = plan

  variables {
    memory_mb = 256
    min_scale = 1
  }

  expect_failures = [terraform_data.target]
}

run "paying_lifts_the_limit" {
  command = plan

  variables {
    memory_mb                      = 1024
    min_scale                      = 1
    acknowledge_billable_resources = true
  }

  assert {
    condition     = output.platforms[0].settings.mvcpu == 560
    error_message = "With acknowledge_billable_resources, any size can stay on."
  }
}

run "sizes_scaleway_does_not_sell_are_refused" {
  command = plan

  variables {
    memory_mb = 300
  }

  expect_failures = [var.memory_mb]
}
