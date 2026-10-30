output "cluster" {
  description = "The cluster, and the command that writes its kubeconfig."
  value = {
    id                 = oci_containerengine_cluster.this.id
    name               = oci_containerengine_cluster.this.name
    kubernetes_version = oci_containerengine_cluster.this.kubernetes_version
    region             = var.region
    nodes              = var.node_count
    arm_ocpus          = local.total_ocpus
    arm_memory_gbs     = local.total_memory
    kubeconfig_command = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.this.id} --region ${var.region} --file $HOME/.kube/config --kube-endpoint PUBLIC_ENDPOINT --token-version 2.0.0"
  }
}
