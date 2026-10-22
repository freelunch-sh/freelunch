# Runs offline: `terraform test` / `tofu test` from shared/modules/docker-bootstrap.

run "minimal_host_is_valid_cloud_config" {
  command = plan

  assert {
    condition     = startswith(output.user_data, "#cloud-config\n")
    error_message = "User data must start with #cloud-config."
  }

  assert {
    condition     = can(yamldecode(output.user_data))
    error_message = "Rendered cloud-init must be valid YAML."
  }

  assert {
    condition     = !can(yamldecode(output.user_data).write_files) && !can(yamldecode(output.user_data).swap)
    error_message = "No write_files or swap sections expected without apps or swap."
  }
}

run "apps_swap_and_tailscale_render" {
  command = plan

  variables {
    swap_size_gb       = 2
    tailscale_auth_key = "tskey-auth-test"
    tailscale_hostname = "host-1"
    extra_runcmd       = ["echo 'quoted: \"value\"'"]
    apps = {
      whoami = {
        compose = "services:\n  whoami:\n    image: traefik/whoami\n"
        env     = { FOO = "bar" }
      }
    }
  }

  assert {
    condition     = yamldecode(output.user_data).swap.size == 2147483648
    error_message = "Swap size should be rendered in bytes."
  }

  assert {
    condition     = base64decode(yamldecode(output.user_data).write_files[0].content) == "services:\n  whoami:\n    image: traefik/whoami\n"
    error_message = "Compose file should round-trip through base64."
  }

  assert {
    condition     = base64decode(yamldecode(output.user_data).write_files[1].content) == "FOO=bar"
    error_message = "Env file should contain app env vars."
  }

  assert {
    condition     = contains(yamldecode(output.user_data).runcmd, "echo 'quoted: \"value\"'")
    error_message = "extra_runcmd must survive YAML quoting unchanged."
  }

  assert {
    condition     = contains(yamldecode(output.user_data).runcmd, "tailscale up --auth-key=tskey-auth-test --hostname=host-1")
    error_message = "Tailscale join command missing."
  }

  assert {
    condition     = contains(yamldecode(output.user_data).runcmd, "cd /opt/freelunch/apps/whoami && docker compose up -d")
    error_message = "App start command missing."
  }
}

run "ssh_keys_render_for_the_default_user" {
  command = plan

  variables {
    ssh_authorized_keys = ["ssh-ed25519 AAAAone a@laptop", "ssh-rsa AAAAtwo b@desktop"]
  }

  assert {
    condition     = yamldecode(output.user_data).ssh_authorized_keys == ["ssh-ed25519 AAAAone a@laptop", "ssh-rsa AAAAtwo b@desktop"]
    error_message = "Every key should reach cloud-init's ssh_authorized_keys unchanged."
  }
}

run "size_limit_is_enforced" {
  command = plan

  variables {
    max_encoded_size_bytes = 100
  }

  expect_failures = [output.user_data]
}

run "invalid_app_name_is_rejected" {
  command = plan

  variables {
    apps = { "My App" = { compose = "services: {}" } }
  }

  expect_failures = [var.apps]
}
