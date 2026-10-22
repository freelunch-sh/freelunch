# Runs offline: `terraform test` / `tofu test` from providers/aws/modules/docker-host.

mock_provider "aws" {}

variables {
  region          = "us-east-1"
  ssh_public_keys = ["ssh-ed25519 AAAAone a@laptop", "ssh-ed25519 AAAAtwo b@desktop"]
}

run "every_ssh_key_reaches_cloud_init" {
  command = plan

  assert {
    condition     = yamldecode(module.bootstrap["main"].user_data).ssh_authorized_keys == ["ssh-ed25519 AAAAone a@laptop", "ssh-ed25519 AAAAtwo b@desktop"]
    error_message = "A key pair holds one key, so every key must be installed by cloud-init."
  }

  assert {
    condition     = yamldecode(module.bootstrap["main"].user_data).swap.size == 2147483648
    error_message = "1 GB hosts should get 2 GB of swap by default."
  }
}
