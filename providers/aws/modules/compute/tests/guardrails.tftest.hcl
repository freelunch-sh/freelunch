# Runs offline: `terraform test` / `tofu test` from providers/aws/modules/compute.

mock_provider "aws" {
  mock_data "aws_ami" {
    defaults = {
      id = "ami-0123456789abcdef0"
    }
  }
}

variables {
  region             = "us-east-1"
  subnet_id          = "subnet-mock"
  security_group_ids = ["sg-mock"]
}

run "free_plan_layout_passes" {
  command = plan

  variables {
    instances = { main = {} }
  }

  assert {
    condition     = aws_instance.this["main"].instance_type == "t3.micro" && aws_instance.this["main"].credit_specification[0].cpu_credits == "standard"
    error_message = "Default should be a t3.micro with standard CPU credits."
  }

  assert {
    condition     = aws_instance.this["main"].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 should be required."
  }

  assert {
    condition = (
      aws_instance.this["main"].root_block_device[0].volume_type == "gp3" &&
      aws_instance.this["main"].root_block_device[0].volume_size == 20 &&
      aws_instance.this["main"].root_block_device[0].encrypted
    )
    error_message = "Root volume should be a 20 GB encrypted gp3 volume."
  }

  assert {
    condition     = output.free_tier_usage.free_plan_eligible && output.hosts[0].arch == "amd64"
    error_message = "t3.micro is a Free plan x86 type."
  }
}

run "graviton_is_arm64_and_uses_the_arm_ami" {
  command = plan

  variables {
    instances = { main = { instance_type = "t4g.small" } }
  }

  assert {
    condition = keys(data.aws_ami.ubuntu) == ["arm64"] && anytrue([
      for f in data.aws_ami.ubuntu["arm64"].filter : f.name == "name" && anytrue([for v in f.values : strcontains(v, "-arm64-server-")])
    ])
    error_message = "t4g should look up the arm64 Ubuntu AMI."
  }

  assert {
    condition     = output.hosts[0].arch == "arm64"
    error_message = "t4g hosts are arm64."
  }
}

run "flex_types_take_no_credit_specification" {
  command = plan

  variables {
    instances = { main = { instance_type = "c7i-flex.large" } }
  }

  assert {
    condition     = length(aws_instance.this["main"].credit_specification) == 0
    error_message = "Only burstable t-family instances take a credit specification."
  }
}

run "non_free_plan_type_is_blocked" {
  command = plan

  variables {
    instances = { main = { instance_type = "t3.medium" } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "unlimited_credits_are_blocked" {
  command = plan

  variables {
    instances = { main = { cpu_credits = "unlimited" } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "non_general_purpose_root_volume_is_blocked" {
  command = plan

  variables {
    instances = { main = { root_volume_type = "io2" } }
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "tiny_root_volume_is_blocked_even_when_acknowledged" {
  command = plan

  variables {
    instances                      = { main = { root_volume_gb = 4 } }
    acknowledge_billable_resources = true
  }

  expect_failures = [terraform_data.free_tier_guardrails]
}

run "acknowledged_billing_allows_other_types" {
  command = plan

  variables {
    instances                      = { main = { instance_type = "m7g.large" } }
    acknowledge_billable_resources = true
  }

  assert {
    condition     = !output.free_tier_usage.free_plan_eligible && output.hosts[0].arch == "arm64"
    error_message = "Usage output should report the non-eligible type."
  }
}
