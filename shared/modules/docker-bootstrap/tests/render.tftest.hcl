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
    condition     = !can(yamldecode(output.user_data).swap)
    error_message = "No swap section expected without swap."
  }

  assert {
    condition = (
      [for f in yamldecode(output.user_data).write_files : f.path] ==
      ["/etc/ssh/sshd_config.d/10-freelunch.conf", "/etc/docker/daemon.json", "/etc/apt/apt.conf.d/52freelunch-reboot"]
    )
    error_message = "Every host gets the SSH, Docker log and reboot settings, and nothing else without apps or Tailscale."
  }
}

run "hosts_are_hardened" {
  command = plan

  assert {
    condition = alltrue([
      for line in ["PasswordAuthentication no", "KbdInteractiveAuthentication no", "PermitRootLogin no"] :
      strcontains(one([for f in yamldecode(output.user_data).write_files : f.content if f.path == "/etc/ssh/sshd_config.d/10-freelunch.conf"]), line)
    ])
    error_message = "sshd should allow keys only and no root login."
  }

  assert {
    condition = jsondecode(one([for f in yamldecode(output.user_data).write_files : f.content if f.path == "/etc/docker/daemon.json"])) == {
      log-driver = "json-file"
      log-opts   = { max-size = "10m", max-file = "3" }
    }
    error_message = "Docker should rotate container logs."
  }

  assert {
    condition     = strcontains(one([for f in yamldecode(output.user_data).write_files : f.content if f.path == "/etc/apt/apt.conf.d/52freelunch-reboot"]), "Unattended-Upgrade::Automatic-Reboot-Time \"04:00\";")
    error_message = "Hosts should reboot at 04:00 when a security update needs it."
  }
}

run "automatic_reboots_can_be_turned_off" {
  command = plan

  variables {
    reboot_time = null
  }

  assert {
    condition     = !contains([for f in yamldecode(output.user_data).write_files : f.path], "/etc/apt/apt.conf.d/52freelunch-reboot")
    error_message = "With reboot_time = null, no reboot policy should be written."
  }
}

run "reboot_time_must_be_a_time_of_day" {
  command = plan

  variables {
    reboot_time = "4am"
  }

  expect_failures = [var.reboot_time]
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
    condition     = base64decode(one([for f in yamldecode(output.user_data).write_files : f.content if f.path == "/opt/freelunch/apps/whoami/compose.yaml"])) == "services:\n  whoami:\n    image: traefik/whoami\n"
    error_message = "Compose file should round-trip through base64."
  }

  assert {
    condition     = base64decode(one([for f in yamldecode(output.user_data).write_files : f.content if f.path == "/opt/freelunch/apps/whoami/.env"])) == "FOO=bar"
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
    condition = (
      startswith(base64decode(one([for f in yamldecode(output.user_data).write_files : f.content if f.path == "/usr/share/keyrings/tailscale-archive-keyring.asc"])), "-----BEGIN PGP PUBLIC KEY BLOCK-----") &&
      anytrue([for c in yamldecode(output.user_data).runcmd : strcontains(c, "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.asc] https://pkgs.tailscale.com/stable/ubuntu ")]) &&
      anytrue([for c in yamldecode(output.user_data).runcmd : strcontains(c, "apt-get install -y -q tailscale")])
    )
    error_message = "Tailscale should come from its apt repository, checked against the pinned signing key."
  }

  assert {
    condition     = !strcontains(output.user_data, "curl")
    error_message = "Nothing should be piped from the internet into a shell."
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
