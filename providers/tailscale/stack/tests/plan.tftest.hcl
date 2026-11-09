# Runs offline: `terraform test` / `tofu test` from providers/tailscale/stack.
# Plans the stack against a mocked Tailscale API and a fixture inventory.

mock_provider "tailscale" {
  mock_resource "tailscale_tailnet_key" {
    defaults = {
      key = "tskey-auth-mock"
    }
  }
  mock_data "tailscale_device" {
    defaults = {
      addresses = ["100.64.0.7", "fd7a:115c:a1e0::7"]
    }
  }
}

variables {
  name_prefix          = "shop"
  inventory_state_path = "../../../hybrid/tests/fixtures/oci.tfstate"
}

run "a_join_key_hosts_use_on_first_boot" {
  command = plan

  assert {
    condition     = tailscale_tailnet_key.join.reusable && tailscale_tailnet_key.join.preauthorized && !tailscale_tailnet_key.join.ephemeral && tailscale_tailnet_key.join.expiry == 90 * 86400
    error_message = "The join key is reusable and preauthorized, and expires."
  }
}

run "hosts_are_looked_up_by_the_name_the_bootstrap_gives_them" {
  command = plan

  assert {
    condition     = data.tailscale_device.host["oci-main"].hostname == "shop-oci-main" && data.tailscale_device.host["oci-edge-1"].hostname == "shop-oci-edge-1"
    error_message = "A host registers as <name_prefix>-<provider>-<name>."
  }

  assert {
    condition     = output.mesh["oci-main"].address == "100.64.0.7" && output.mesh["oci-main"].ssh == false
    error_message = "The mesh contract gives each host's tailnet address; ssh is off unless asked for."
  }
}

run "ssh_over_the_mesh_is_opt_in" {
  command = plan

  variables {
    ssh = true
  }

  assert {
    condition     = output.mesh["oci-main"].ssh == true
    error_message = "ssh = true makes deploy go over the mesh."
  }
}
