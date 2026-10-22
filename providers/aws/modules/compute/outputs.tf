output "hosts" {
  description = "Created instances in the freelunch host contract shape (docs/architecture.md)."
  value = [
    for k, i in aws_instance.this : {
      provider   = "aws"
      name       = k
      id         = i.id
      public_ip  = i.public_ip != "" ? i.public_ip : null
      private_ip = i.private_ip
      ssh_user   = var.ssh_user
      arch       = local.instance_arch[k]
      region     = var.region
      size       = i.instance_type
    }
  ]
}

output "free_tier_usage" {
  description = "What this module plans. On the Free plan all of it draws down the credit."
  value = {
    free_plan_eligible = alltrue([for i in var.instances : contains(local.free_types, i.instance_type)])
    instances          = length(var.instances)
    ebs_gb             = local.ebs_gb
    public_ipv4        = local.public_ipv4
  }
}
