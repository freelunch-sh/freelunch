locals {
  free_tier = yamldecode(file("${path.module}/../../provider.yaml")).limits

  free_machine_type = local.free_tier.compute.machine_type
  free_disk_type    = local.free_tier.storage.disk_type

  # Axion (C4A, N4A) and Ampere (T2A) machine types are Arm; everything else is x86.
  instance_arch = { for k, v in var.instances : k => can(regex("^(t2a|c4a|n4a)-", v.machine_type)) ? "arm64" : "amd64" }

  # Zone b exists in all three free-tier regions.
  instance_zone  = { for k, v in var.instances : k => coalesce(v.zone, "${var.region}-b") }
  instance_image = { for k, v in var.instances : k => coalesce(v.image, "ubuntu-os-cloud/ubuntu-2404-lts-${local.instance_arch[k]}") }

  micro_instances  = { for k, v in var.instances : k => v if v.machine_type == local.free_machine_type }
  standard_disk_gb = sum(concat([0], [for v in var.instances : v.disk_gb if v.disk_type == local.free_disk_type]))
  public_ipv4      = length([for v in var.instances : v if v.assign_public_ip])

  labels = { "managed-by" = "freelunch" }
}

resource "terraform_data" "free_tier_guardrails" {
  input = {
    micro_instances  = length(local.micro_instances)
    standard_disk_gb = local.standard_disk_gb
    public_ipv4      = local.public_ipv4
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || contains(local.free_tier.compute.regions, var.region)
      error_message = "Region ${var.region} has no free e2-micro. Use one of ${join(", ", local.free_tier.compute.regions)}, or set acknowledge_billable_resources = true."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for i in var.instances : i.machine_type == local.free_machine_type])
      error_message = "Only ${local.free_machine_type} is free. Set acknowledge_billable_resources = true to use other machine types."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || length(var.instances) <= local.free_tier.compute.max_instances
      error_message = "The free tier covers ${local.free_tier.compute.max_instances} ${local.free_machine_type} running all month; ${length(var.instances)} instances would be billed for the extra hours."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for i in var.instances : i.disk_type == local.free_disk_type])
      error_message = "Only ${local.free_disk_type} disks are free (pd-balanced, the console default, is billed)."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || local.standard_disk_gb <= local.free_tier.storage.max_disk_gb
      error_message = "Boot disks total ${local.standard_disk_gb} GB; the free tier covers ${local.free_tier.storage.max_disk_gb} GB of ${local.free_disk_type}."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || var.acknowledge_public_ipv4_charge || local.public_ipv4 == 0
      error_message = "External IPv4 addresses are billed at $0.005/h (about $3.65/month each) and are not part of the free tier; the $300 trial credit covers them while it lasts. Set acknowledge_public_ipv4_charge = true to accept the charge, or assign_public_ip = false (the VM then has no internet access without Cloud NAT, which is billed too)."
    }

    precondition {
      condition     = alltrue([for i in var.instances : i.disk_gb >= local.free_tier.storage.min_boot_disk_gb])
      error_message = "Boot disks must be at least ${local.free_tier.storage.min_boot_disk_gb} GB."
    }

    precondition {
      condition     = alltrue([for k, z in local.instance_zone : startswith(z, "${var.region}-")])
      error_message = "Every zone must be in region ${var.region}."
    }
  }
}

resource "google_compute_instance" "this" {
  for_each = var.instances

  name                      = "${var.name_prefix}-${each.key}"
  machine_type              = each.value.machine_type
  zone                      = local.instance_zone[each.key]
  labels                    = local.labels
  allow_stopping_for_update = true

  boot_disk {
    auto_delete = true

    initialize_params {
      image  = local.instance_image[each.key]
      size   = each.value.disk_gb
      type   = each.value.disk_type
      labels = local.labels
    }
  }

  network_interface {
    subnetwork = var.subnet_id

    dynamic "access_config" {
      for_each = each.value.assign_public_ip ? [1] : []
      content {
        network_tier = each.value.network_tier
      }
    }
  }

  # cloud-init reads `user-data`; the guest agent and cloud-init both read `ssh-keys`.
  # OS Login would make the instance ignore metadata SSH keys.
  metadata = merge(
    {
      ssh-keys       = join("\n", [for key in var.ssh_public_keys : "${var.ssh_user}:${key}"])
      enable-oslogin = "FALSE"
    },
    each.value.user_data != null ? { user-data = each.value.user_data } : {},
  )

  # Spot and preemptible VMs are not covered by the free tier.
  scheduling {
    provisioning_model  = "STANDARD"
    preemptible         = false
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    # A newer image in the family or edited cloud-init must not rebuild a running host;
    # cloud-init only runs on first boot anyway. Rebuild deliberately with `-replace`.
    # SSH keys stay managed: changes apply in place without a reboot.
    ignore_changes = [boot_disk[0].initialize_params[0].image, metadata["user-data"]]
  }

  depends_on = [terraform_data.free_tier_guardrails]
}
