# Runs offline: `terraform test` / `tofu test` from providers/backblaze-b2/stack.
# Plans the stack against a mocked B2 API.

mock_provider "b2" {
  mock_data "b2_account_info" {
    defaults = { s3_api_url = "https://s3.us-west-004.backblazeb2.com" }
  }

  mock_resource "b2_bucket" {
    defaults = { bucket_id = "4a48fe8875c6214145260818" }
  }

  mock_resource "b2_application_key" {
    defaults = { application_key_id = "0044a48fe88000000000001", application_key = "K004mock" }
  }
}

variables {
  name_prefix = "shop"
  buckets     = { results = {} }
}

run "a_private_bucket_named_after_the_project" {
  command = plan

  assert {
    condition     = b2_bucket.this["results"].bucket_name == "shop-results" && b2_bucket.this["results"].bucket_type == "allPrivate"
    error_message = "A bucket is private, and named <name_prefix>-<name>."
  }

  assert {
    condition     = one(b2_bucket.this["results"].lifecycle_rules).days_from_hiding_to_deleting == 1
    error_message = "Old versions go after a day, so they don't fill the free 10 GB."
  }
}

run "the_key_only_reaches_its_bucket" {
  command = apply

  assert {
    condition     = b2_application_key.this["results"].bucket_ids == toset(["4a48fe8875c6214145260818"]) && !contains(b2_application_key.this["results"].capabilities, "writeKeys")
    error_message = "Each bucket's key is restricted to that bucket and can't make keys."
  }

  assert {
    condition = output.buckets == [{
      provider = "backblaze-b2", name = "results", bucket = "shop-results",
      endpoint = "https://s3.us-west-004.backblazeb2.com", region = "us-west-004"
    }]
    error_message = "The storage contract: provider, name, bucket, S3 endpoint and region."
  }

  assert {
    condition     = nonsensitive(output.bucket_keys["backblaze-b2-results"]) == { access_key_id = "0044a48fe88000000000001", secret_access_key = "K004mock" }
    error_message = "deploy finds the key as backblaze-b2-<name>."
  }
}

run "a_bucket_can_have_a_name_of_its_own" {
  command = plan

  variables {
    buckets = { results = { name = "acme-ci-results-2026" } }
  }

  assert {
    condition     = b2_bucket.this["results"].bucket_name == "acme-ci-results-2026"
    error_message = "name gives the whole bucket name."
  }
}

run "names_b2_refuses_fail" {
  command = plan

  variables {
    buckets = { results = { name = "b2-results" } }
  }

  expect_failures = [terraform_data.checks]
}
