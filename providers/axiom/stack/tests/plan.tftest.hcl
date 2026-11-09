# Runs offline: `terraform test` / `tofu test` from providers/axiom/stack, against a mocked Axiom API.

mock_provider "axiom" {
  mock_resource "axiom_token" {
    defaults = {
      token = "xaat-mock-ingest-token"
    }
  }
}

variables {
  name_prefix = "shop"
}

run "a_dataset_and_an_ingest_only_token" {
  command = plan

  assert {
    condition     = axiom_dataset.this["logs"].name == "shop-logs" && axiom_dataset.this["logs"].retention_days == 30
    error_message = "A dataset is <name_prefix>-<name>, kept 30 days."
  }

  assert {
    condition     = join(",", axiom_token.ingest["logs"].dataset_capabilities["shop-logs"].ingest) == "create" && axiom_token.ingest["logs"].org_capabilities == null
    error_message = "The token can only ingest into its dataset and has no organisation rights."
  }
}

run "outputs_follow_the_service_contract" {
  command = apply

  assert {
    condition     = output.services[0].provider == "axiom" && output.services[0].name == "logs" && output.services[0].kind == "observability" && output.services[0].host == "api.axiom.co"
    error_message = "services lists the dataset as an observability service."
  }

  assert {
    condition     = nonsensitive(output.service_credentials["axiom-logs"].env) == { AXIOM_TOKEN = "xaat-mock-ingest-token", AXIOM_DATASET = "shop-logs" }
    error_message = "An app gets the ingest token and the dataset's name."
  }
}

run "several_datasets_get_names_of_their_own_too" {
  command = apply

  variables {
    datasets = { logs = {}, traces = { retention_days = 7 } }
  }

  assert {
    condition     = nonsensitive(output.service_credentials["axiom-traces"].env.AXIOM_DATASET_TRACES) == "shop-traces"
    error_message = "With more than one dataset each is also named under its own variable."
  }
}

run "more_than_30_days_is_not_free" {
  command = plan

  variables {
    datasets = { logs = { retention_days = 90 } }
  }

  expect_failures = [var.datasets]
}
