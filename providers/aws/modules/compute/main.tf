locals {
  free_tier = yamldecode(file("${path.module}/../../provider.yaml")).limits

  free_types   = local.free_tier.compute.free_plan_instance_types
  volume_types = local.free_tier.storage.volume_types

  # Graviton families carry a "g" after the generation number: t4g, m7g, c7gn, x2gd.
  instance_arch = { for k, v in var.instances : k => can(regex("^[a-z]+[0-9]+g[a-z]*\\.", v.instance_type)) ? "arm64" : "amd64" }
  burstable     = { for k, v in var.instances : k => can(regex("^t[0-9]+[a-z]*\\.", v.instance_type)) }

  ebs_gb      = sum(concat([0], [for v in var.instances : v.root_volume_gb]))
  public_ipv4 = length([for v in var.instances : v if v.assign_public_ip])

  tags = { "managed-by" = "freelunch" }
}

data "aws_ami" "ubuntu" {
  for_each = toset(values(local.instance_arch))

  owners      = ["099720109477"] # Canonical
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-${var.ubuntu_codename}-${var.ubuntu_version}-${each.key}-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "terraform_data" "free_tier_guardrails" {
  input = {
    instances   = length(var.instances)
    ebs_gb      = local.ebs_gb
    public_ipv4 = local.public_ipv4
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for i in var.instances : contains(local.free_types, i.instance_type)])
      error_message = "Only ${join(", ", local.free_types)} are eligible on the AWS Free plan. Set acknowledge_billable_resources = true to use other types (Free plan accounts must upgrade to a paid plan first)."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for i in var.instances : contains(local.volume_types, i.root_volume_type)])
      error_message = "Use a ${join(" or ", local.volume_types)} root volume; other volume types are not Free tier eligible as boot disks."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for k, i in var.instances : !local.burstable[k] || i.cpu_credits == local.free_tier.compute.cpu_credits])
      error_message = "Burstable instances with cpu_credits = \"unlimited\" bill every vCPU-hour above baseline. Use \"${local.free_tier.compute.cpu_credits}\", or set acknowledge_billable_resources = true."
    }

    precondition {
      condition     = alltrue([for i in var.instances : i.root_volume_gb >= local.free_tier.storage.min_root_volume_gb])
      error_message = "Root volumes must be at least ${local.free_tier.storage.min_root_volume_gb} GB."
    }
  }
}

resource "aws_instance" "this" {
  for_each = var.instances

  ami                         = data.aws_ami.ubuntu[local.instance_arch[each.key]].id
  instance_type               = each.value.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = each.value.assign_public_ip
  key_name                    = var.key_name
  user_data_base64            = each.value.user_data != null ? base64encode(each.value.user_data) : null
  user_data_replace_on_change = false
  tags                        = merge(local.tags, { Name = "${var.name_prefix}-${each.key}" })

  # t2/t3/t4g launch with "unlimited" CPU credits by default: sustained load above the
  # baseline is billed per vCPU-hour. "standard" throttles instead.
  dynamic "credit_specification" {
    for_each = local.burstable[each.key] ? [1] : []
    content {
      cpu_credits = each.value.cpu_credits
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  root_block_device {
    volume_type           = each.value.root_volume_type
    volume_size           = each.value.root_volume_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = merge(local.tags, { Name = "${var.name_prefix}-${each.key}-root" })
  }

  lifecycle {
    # A newer AMI or edited cloud-init must not rebuild a running host; cloud-init only
    # runs on first boot anyway. Rebuild deliberately with `-replace`.
    ignore_changes = [ami, user_data, user_data_base64]
  }

  depends_on = [terraform_data.free_tier_guardrails]
}
