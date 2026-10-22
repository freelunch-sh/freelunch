# Runs offline: `terraform test` / `tofu test` from providers/aws/stack.
# Plans the whole stack (network + bootstrap + compute) against a mocked AWS API.

mock_provider "aws" {}

variables {
  region          = "us-east-1"
  ssh_public_keys = ["ssh-ed25519 AAAAmock test"]
}

run "default_stack_plans" {
  command = plan

  assert {
    condition     = output.free_tier_usage.free_plan_eligible && output.free_tier_usage.instances == 1 && output.free_tier_usage.ebs_gb == 20
    error_message = "Default layout should be one Free plan t3.micro with 20 GB of gp3."
  }

  assert {
    condition     = length(output.hosts) == 1 && output.hosts[0].provider == "aws" && output.hosts[0].arch == "amd64" && output.hosts[0].region == "us-east-1"
    error_message = "hosts output must follow the freelunch host contract."
  }

  assert {
    condition     = keys(output.hosts[0]) == ["arch", "id", "name", "private_ip", "provider", "public_ip", "region", "size", "ssh_user"]
    error_message = "hosts must carry exactly the host contract attributes."
  }
}
