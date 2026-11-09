# Runs offline: `terraform test` / `tofu test` from providers/cloudflare/modules/edge.

mock_provider "cloudflare" {}

variables {
  account_id = "699d98642c564d2e855e9661899b7252"
  zone       = "example.com"
}

run "empty_by_default" {
  command = plan

  assert {
    condition     = length(cloudflare_workers_script.this) == 0 && length(cloudflare_pages_project.this) == 0
    error_message = "With no workers or pages the module should make nothing."
  }
}

run "a_worker_and_a_pages_project_on_custom_domains" {
  command = plan

  variables {
    workers = { api = { script_file = "fixtures/worker.js", hostname = "api.example.com" } }
    pages   = { site = { hostname = "www.example.com" } }
  }

  assert {
    condition     = cloudflare_workers_script.this["api"].script_name == "freelunch-api" && cloudflare_workers_custom_domain.this["api"].hostname == "api.example.com"
    error_message = "A Worker is <prefix>-<name> and is bound to its hostname."
  }

  assert {
    condition     = cloudflare_pages_project.this["site"].name == "freelunch-site" && cloudflare_pages_domain.this["site"].name == "www.example.com"
    error_message = "A Pages project is <prefix>-<name> with its custom domain."
  }
}

run "a_worker_without_hostname_has_no_custom_domain" {
  command = plan

  variables {
    workers = { api = { script_file = "fixtures/worker.js" } }
  }

  assert {
    condition     = length(cloudflare_workers_custom_domain.this) == 0
    error_message = "Without a hostname the Worker stays on workers.dev."
  }
}

run "hostname_outside_the_zone_is_rejected" {
  command = plan

  variables {
    workers = { api = { script_file = "fixtures/worker.js", hostname = "api.other.org" } }
  }

  expect_failures = [terraform_data.checks]
}

run "duplicate_hostname_is_rejected" {
  command = plan

  variables {
    workers = { api = { script_file = "fixtures/worker.js", hostname = "www.example.com" } }
    pages   = { site = { hostname = "www.example.com" } }
  }

  expect_failures = [terraform_data.checks]
}

run "more_workers_than_the_free_plan_needs_an_acknowledgement" {
  command = plan

  variables {
    workers = { for i in range(101) : "w${i}" => { script_file = "fixtures/worker.js" } }
  }

  expect_failures = [terraform_data.checks]
}

run "acknowledged_overflow_plans" {
  command = plan

  variables {
    workers                        = { for i in range(101) : "w${i}" => { script_file = "fixtures/worker.js" } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = length(cloudflare_workers_script.this) == 101
    error_message = "With the acknowledgement the 101 Workers should plan."
  }
}
