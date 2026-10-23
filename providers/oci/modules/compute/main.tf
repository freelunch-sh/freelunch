locals {
  free_tier = yamldecode(file("${path.module}/../../provider.yaml")).limits

  a1_shape    = local.free_tier.compute.a1_flex.shape
  micro_shape = local.free_tier.compute.e2_micro.shape
  free_shapes = [local.a1_shape, local.micro_shape]

  shapes = toset([for i in var.instances : i.shape])

  a1_instances    = { for k, v in var.instances : k => v if v.shape == local.a1_shape }
  micro_instances = { for k, v in var.instances : k => v if v.shape == local.micro_shape }

  a1_ocpus         = sum(concat([0], [for v in local.a1_instances : v.ocpus]))
  a1_memory_gb     = sum(concat([0], [for v in local.a1_instances : v.memory_in_gbs]))
  block_storage_gb = sum(concat([var.reserved_block_storage_gb], [for v in var.instances : v.boot_volume_gb]))

  home_region = one([
    for s in data.oci_identity_region_subscriptions.this.region_subscriptions : s.region_name if s.is_home_region
  ])

  ad_names      = [for ad in data.oci_identity_availability_domains.this.availability_domains : ad.name]
  shapes_by_ad  = { for ad, d in data.oci_core_shapes.by_ad : ad => [for s in d.shapes : s.name] }
  ads_for_shape = { for shape in local.shapes : shape => [for ad in local.ad_names : ad if contains(local.shapes_by_ad[ad], shape)] }

  # element() wraps around, so any offset lands on an AD that offers the shape.
  instance_ad = {
    for k, v in var.instances : k => (
      v.availability_domain_index != null
      ? local.ad_names[v.availability_domain_index]
      : try(element(local.ads_for_shape[v.shape], var.availability_domain_offset), local.ad_names[0])
    )
  }

  freeform_tags = { "managed-by" = "freelunch" }
}

data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_id
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_id
}

# The Always Free micro shape is offered in only one AD of multi-AD regions; looking up
# shapes per AD lets us place each instance where its shape exists.
data "oci_core_shapes" "by_ad" {
  for_each = toset(local.ad_names)

  compartment_id      = var.compartment_id
  availability_domain = each.key
}

data "oci_core_images" "this" {
  for_each = local.shapes

  compartment_id           = var.compartment_id
  operating_system         = var.operating_system
  operating_system_version = var.operating_system_version
  shape                    = each.key
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "terraform_data" "free_tier_guardrails" {
  input = {
    a1_ocpus         = local.a1_ocpus
    a1_memory_gb     = local.a1_memory_gb
    micro_count      = length(local.micro_instances)
    block_storage_gb = local.block_storage_gb
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || var.region == local.home_region
      error_message = "Region ${var.region} is not the tenancy home region (${coalesce(local.home_region, "unknown")}). Always Free resources only exist in the home region; elsewhere everything is billed. Set acknowledge_billable_resources = true to proceed anyway."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || alltrue([for i in var.instances : contains(local.free_shapes, i.shape)])
      error_message = "Only ${join(" and ", local.free_shapes)} are Always Free. Set acknowledge_billable_resources = true to use other shapes."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || (local.a1_ocpus <= local.free_tier.compute.a1_flex.max_ocpus && local.a1_memory_gb <= local.free_tier.compute.a1_flex.max_memory_gb)
      error_message = "A1 instances request ${local.a1_ocpus} OCPUs / ${local.a1_memory_gb} GB; the Always Free cap is ${local.free_tier.compute.a1_flex.max_ocpus} OCPUs / ${local.free_tier.compute.a1_flex.max_memory_gb} GB in total (reduced in June 2026)."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || length(local.micro_instances) <= local.free_tier.compute.e2_micro.max_instances
      error_message = "At most ${local.free_tier.compute.e2_micro.max_instances} ${local.micro_shape} instances are Always Free."
    }

    precondition {
      condition     = var.acknowledge_billable_resources || local.block_storage_gb <= local.free_tier.storage.max_block_storage_gb
      error_message = "Boot volumes plus reserved storage total ${local.block_storage_gb} GB; the Always Free cap is ${local.free_tier.storage.max_block_storage_gb} GB."
    }

    precondition {
      condition     = alltrue([for i in var.instances : i.boot_volume_gb >= local.free_tier.storage.min_boot_volume_gb])
      error_message = "Boot volumes must be at least ${local.free_tier.storage.min_boot_volume_gb} GB."
    }
  }
}

resource "oci_core_instance" "this" {
  for_each = var.instances

  compartment_id      = var.compartment_id
  availability_domain = local.instance_ad[each.key]
  display_name        = "${var.name_prefix}-${each.key}"
  shape               = each.value.shape
  freeform_tags       = local.freeform_tags

  dynamic "shape_config" {
    for_each = endswith(each.value.shape, ".Flex") ? [1] : []
    content {
      ocpus         = each.value.ocpus
      memory_in_gbs = each.value.memory_in_gbs
    }
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.this[each.value.shape].images[0].id
    boot_volume_size_in_gbs = each.value.boot_volume_gb
  }

  create_vnic_details {
    subnet_id        = var.subnet_id
    assign_public_ip = each.value.assign_public_ip
    display_name     = "${var.name_prefix}-${each.key}-vnic"
    hostname_label   = each.key
  }

  instance_options {
    are_legacy_imds_endpoints_disabled = true
  }

  metadata = merge(
    { ssh_authorized_keys = join("\n", var.ssh_public_keys) },
    each.value.user_data != null ? { user_data = base64encode(each.value.user_data) } : {},
  )

  preserve_boot_volume = var.preserve_boot_volume

  lifecycle {
    # A newer platform image, edited cloud-init or another availability domain (the next
    # capacity retry, or a new index) must not replace a running host: recreating an A1
    # instance can fail for weeks on "Out of host capacity". Rebuild deliberately with
    # `-replace` instead.
    ignore_changes = [source_details[0].source_id, metadata, availability_domain]

    precondition {
      condition     = length(data.oci_core_images.this[each.value.shape].images) > 0
      error_message = "No ${var.operating_system} ${var.operating_system_version} image found for ${each.value.shape} in ${var.region}."
    }
  }

  depends_on = [terraform_data.free_tier_guardrails]
}
