output "mesh_join_key" {
  description = "The auth key for tailscale_auth_key in the host stacks' tfvars."
  value       = tailscale_tailnet_key.join.key
  sensitive   = true
}

# `mesh` is the freelunch mesh contract (docs/graph.md#the-mesh): per host, the address
# other nodes reach it at, and whether deploy should SSH to it there.
output "mesh" {
  description = "Per host (<provider>-<name>), its tailnet address."
  value = {
    for h, d in data.tailscale_device.host : h => {
      address = d.addresses[0]
      ssh     = var.ssh
    }
  }
}
