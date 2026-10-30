# Runs offline: `terraform test` / `tofu test` from providers/cloud-run/stack.
# The stack has no provider, so there is nothing to mock.

variables {
  project_id = "my-gcp-project"
}

run "scale_to_zero_and_no_tunnel_by_default" {
  command = plan

  assert {
    condition = output.platforms[0] == {
      provider      = "cloud-run"
      name          = "main"
      id            = "my-gcp-project"
      region        = "us-central1"
      arch          = "amd64"
      size          = "1 vCPU, 512Mi"
      tunnel        = false
      max_services  = null
      volume_size   = null
      pricing       = { budget = null, service = null, tunnel = null, volume_gb = null }
      settings      = { label = "freelunch", cpu = "1", memory = "512Mi", max_instances = 1 }
    }
    error_message = "The default target is one instance of 1 vCPU and 512 MiB per service, with no tunnel and no volumes."
  }
}

run "the_label_is_the_project_name" {
  command = plan

  variables {
    name_prefix = "sunbird"
    region      = "europe-west1"
    memory      = "1Gi"
  }

  assert {
    condition     = output.platforms[0].settings.label == "sunbird" && output.platforms[0].size == "1 vCPU, 1Gi" && terraform_data.target.input.region == "europe-west1"
    error_message = "name_prefix labels the services; region and memory carry over."
  }
}

run "a_project_id_must_be_valid" {
  command = plan

  variables {
    project_id = "My Project"
  }

  expect_failures = [var.project_id]
}

run "less_than_one_cpu_is_refused" {
  command = plan

  variables {
    cpu = "0.5"
  }

  expect_failures = [var.cpu]
}
