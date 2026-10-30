# A free Kubernetes cluster: OKE's Basic cluster has no control-plane fee, and its worker
# nodes are Always Free Arm instances. The stack makes the network, the cluster and one node
# pool, and refuses nodes that use more than the tenancy's free Arm cores.

locals {
  compartment_id = coalesce(var.compartment_ocid, var.tenancy_ocid)
  vcn_cidr       = "10.0.0.0/16"
  subnet_cidr    = "10.0.1.0/24"

  total_ocpus  = var.node_count * var.node_ocpus
  total_memory = var.node_count * var.node_memory_gbs
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_containerengine_cluster_option" "this" {
  cluster_option_id = "all"
  compartment_id    = local.compartment_id
}

data "oci_containerengine_node_pool_option" "this" {
  node_pool_option_id = "all"
  compartment_id      = local.compartment_id
}

locals {
  kubernetes_version = var.kubernetes_version != null ? var.kubernetes_version : element(data.oci_containerengine_cluster_option.this.kubernetes_versions, length(data.oci_containerengine_cluster_option.this.kubernetes_versions) - 1)

  # An OKE Oracle Linux image for Arm, at the cluster's Kubernetes version.
  arm_images = [
    for s in data.oci_containerengine_node_pool_option.this.sources : s.image_id
    if strcontains(s.source_name, "aarch64") && !strcontains(lower(s.source_name), "gpu") && strcontains(s.source_name, trimprefix(local.kubernetes_version, "v"))
  ]
}

resource "oci_core_vcn" "this" {
  compartment_id = local.compartment_id
  display_name   = "${var.name_prefix}-oke"
  cidr_blocks    = [local.vcn_cidr]
  dns_label      = replace("${var.name_prefix}oke", "-", "")
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-oke"
}

resource "oci_core_route_table" "this" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-oke"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_security_list" "this" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${var.name_prefix}-oke"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # Nodes, pods and the control plane talk freely inside the VCN.
  ingress_security_rules {
    source   = local.vcn_cidr
    protocol = "all"
  }

  dynamic "ingress_security_rules" {
    for_each = toset(var.api_source_cidrs)
    content {
      description = "Kubernetes API"
      source      = ingress_security_rules.value
      protocol    = "6"
      tcp_options {
        min = 6443
        max = 6443
      }
    }
  }

  dynamic "ingress_security_rules" {
    for_each = toset([80, 443])
    content {
      description = "tcp/${ingress_security_rules.value}"
      source      = "0.0.0.0/0"
      protocol    = "6"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }

  ingress_security_rules {
    description = "Path MTU discovery"
    source      = "0.0.0.0/0"
    protocol    = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }
}

# One public subnet holds the API endpoint, the nodes and the load balancer.
resource "oci_core_subnet" "this" {
  compartment_id    = local.compartment_id
  vcn_id            = oci_core_vcn.this.id
  display_name      = "${var.name_prefix}-oke"
  cidr_block        = local.subnet_cidr
  dns_label         = "oke"
  route_table_id    = oci_core_route_table.this.id
  security_list_ids = [oci_core_security_list.this.id]
}

resource "oci_containerengine_cluster" "this" {
  compartment_id     = local.compartment_id
  name               = "${var.name_prefix}-oke"
  vcn_id             = oci_core_vcn.this.id
  kubernetes_version = local.kubernetes_version
  # BASIC_CLUSTER has no control-plane fee; ENHANCED_CLUSTER costs money.
  type = "BASIC_CLUSTER"

  endpoint_config {
    subnet_id            = oci_core_subnet.this.id
    is_public_ip_enabled = true
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.this.id]
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || (local.total_ocpus <= var.free_a1_ocpus && local.total_memory <= var.free_a1_memory_gbs)
      error_message = "${var.node_count} node(s) of ${var.node_ocpus} OCPU and ${var.node_memory_gbs} GB use ${local.total_ocpus} OCPUs and ${local.total_memory} GB, and the Always Free Arm allowance is ${var.free_a1_ocpus} OCPUs and ${var.free_a1_memory_gbs} GB, shared with the oci stack's VMs. Use fewer or smaller nodes, raise free_a1_ocpus if your tenancy has more, or set acknowledge_billable_resources = true."
    }
  }
}

resource "oci_containerengine_node_pool" "this" {
  compartment_id     = local.compartment_id
  cluster_id         = oci_containerengine_cluster.this.id
  name               = "${var.name_prefix}-arm"
  kubernetes_version = local.kubernetes_version
  node_shape         = "VM.Standard.A1.Flex"
  ssh_public_key     = var.ssh_public_key

  node_shape_config {
    ocpus         = var.node_ocpus
    memory_in_gbs = var.node_memory_gbs
  }

  node_config_details {
    size = var.node_count

    placement_configs {
      availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
      subnet_id           = oci_core_subnet.this.id
    }
  }

  node_source_details {
    source_type             = "IMAGE"
    image_id                = try(local.arm_images[0], null)
    boot_volume_size_in_gbs = var.node_boot_volume_gb
  }

  lifecycle {
    precondition {
      condition     = length(local.arm_images) > 0
      error_message = "OKE has no Arm node image for Kubernetes ${local.kubernetes_version}. Pick another kubernetes_version (oci ce cluster-options get --cluster-option-id all)."
    }
  }
}
