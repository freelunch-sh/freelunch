output "mesh_join_key" {
  description = "The setup key for netbird_setup_key in the host stacks' tfvars."
  value       = netbird_setup_key.join.key
  sensitive   = true
}

# `mesh` is the freelunch mesh contract (docs/graph.md#the-mesh): per host, the address
# other nodes reach it at, and whether deploy should SSH to it there.
output "mesh" {
  description = "Per host (<provider>-<name>), its NetBird address."
  value = {
    for h, d in data.netbird_peer.host : h => {
      address = d.ip
      ssh     = var.ssh
    }
  }
}
