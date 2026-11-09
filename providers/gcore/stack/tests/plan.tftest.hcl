# Runs offline: `terraform test` / `tofu test` from providers/gcore/stack.
# Plans the stack against a mocked gcore API and a fixture inventory.

mock_provider "gcore" {}

variables {
  zone                 = "example.com"
  inventory_state_path = "../../../hybrid/tests/fixtures/oci.tfstate"
  records = {
    api = { host = "oci-main" }
    www = { type = "CNAME", value = "api.example.com." }
  }
}

run "a_host_becomes_an_a_record_to_its_public_ip" {
  command = plan

  assert {
    condition     = output.dns_records["api.example.com"].type == "A" && output.dns_records["api.example.com"].target == "203.0.113.10"
    error_message = "A record with a host points at the host's public IP."
  }

  assert {
    condition     = output.dns_records["www.example.com"].target == "api.example.com." && output.dns_records["www.example.com"].type == "CNAME"
    error_message = "A record with a value is made as given."
  }
}

run "the_zone_is_made_unless_it_exists" {
  command = plan

  variables {
    create_zone = false
  }

  assert {
    condition     = length(output.dns_records) == 2
    error_message = "With create_zone = false the records are still kept."
  }
}

run "a_host_that_is_not_in_the_inventory_is_refused" {
  command = plan

  variables {
    records = { api = { host = "gcp-nowhere" } }
  }

  expect_failures = [terraform_data.checks]
}

run "a_record_needs_a_host_or_a_value" {
  command = plan

  variables {
    records = { api = {} }
  }

  expect_failures = [var.records]
}

run "an_unknown_type_is_refused" {
  command = plan

  variables {
    records = { api = { type = "MX", value = "mail.example.com." } }
  }

  expect_failures = [var.records]
}
