# Runs offline: `terraform test` / `tofu test` from providers/netbird/stack.
# Plans the stack against a mocked NetBird API and a fixture inventory.

mock_provider "netbird" {
  mock_resource "netbird_setup_key" {
    defaults = {
      key = "AAAAAAAA-0000-1111-2222-333333333333"
    }
  }
  mock_data "netbird_peer" {
    defaults = {
      ip = "100.77.0.7"
    }
  }
}

variables {
  name_prefix          = "shop"
  inventory_state_path = "../../../hybrid/tests/fixtures/oci.tfstate"
}

run "a_reusable_setup_key_that_expires" {
  command = plan

  assert {
    condition     = netbird_setup_key.join.type == "reusable" && !netbird_setup_key.join.ephemeral && netbird_setup_key.join.expiry_seconds == 90 * 86400 && netbird_setup_key.join.name == "shop-hosts"
    error_message = "The setup key is reusable, not ephemeral, and expires."
  }
}

run "hosts_are_looked_up_by_the_name_the_bootstrap_gives_them" {
  command = plan

  assert {
    condition     = data.netbird_peer.host["oci-main"].name == "shop-oci-main" && data.netbird_peer.host["oci-edge-1"].name == "shop-oci-edge-1"
    error_message = "A host registers as <name_prefix>-<provider>-<name>."
  }

  assert {
    condition     = output.mesh["oci-main"].address == "100.77.0.7" && output.mesh["oci-main"].ssh == false
    error_message = "The mesh contract gives each host's address; ssh is off unless asked for."
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
