output "hosts" {
  description = "Every host across providers, in the host contract shape (docs/architecture.md#host-contract)."
  value       = local.hosts
}

output "hosts_by_provider" {
  description = "Host names and public IPs grouped by provider."
  value       = { for p, hs in local.hosts_by_provider : p => { for h in hs : h.name => h.public_ip } }
}

output "ansible_inventory" {
  description = "Ansible YAML inventory with one group per provider and per CPU architecture. Private-only hosts are listed by private IP."
  value = yamlencode({
    all = {
      children = merge(
        { for p, hs in local.hosts_by_provider : p => { hosts = { for h in hs : "${p}-${h.name}" => { ansible_host = coalesce(h.public_ip, h.private_ip), ansible_user = h.ssh_user } } } },
        { for arch in distinct([for h in local.hosts : h.arch]) : arch => { hosts = { for h in local.hosts : "${h.provider}-${h.name}" => {} if h.arch == arch } } },
      )
    }
  })
}

output "ssh_config" {
  description = "OpenSSH config snippet: `freelunch output hybrid -raw ssh_config >> ~/.ssh/config`. Private-only hosts use their private IP (reach them over Tailscale or a VPN)."
  value = join("\n", [
    for h in local.hosts : <<-EOT
      Host ${h.provider}-${h.name}
        HostName ${coalesce(h.public_ip, h.private_ip)}
        User ${h.ssh_user}
    EOT
  ])
}
