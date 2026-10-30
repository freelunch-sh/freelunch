# Oracle Kubernetes Engine (OKE)

| | |
|---|---|
| **Status** | ✅ Implemented (not yet run against a real tenancy) |
| **Category** | Containers & PaaS |
| **Layer** | `service`: a managed cluster; freelunch makes it, you deploy to it with `kubectl` or Helm |
| **Free tier** | ♾️ Always free (the Basic cluster, on Always Free Arm nodes) |
| **Card required** | yes |
| **Terraform provider** | [`oracle/oci`](https://registry.terraform.io/providers/oracle/oci/latest) (official) |
| **Last verified** | 2026-10-30 |

A Kubernetes cluster at no cost: OKE's **Basic** cluster has no control-plane fee, and its
worker nodes are Always Free Arm instances. It is the only free managed Kubernetes this
catalog has found, and the free Arm cores are the most compute any free tier gives.

## What's free

| Resource | Free | Enforced by the stack |
|---|---|---|
| Control plane | Basic cluster (Enhanced is billed) | ✅ `type = "BASIC_CLUSTER"` |
| Worker nodes | Always Free Arm: **2 OCPUs and 12 GB** on new accounts since June 2026, 4 and 24 on older ones | ✅ the plan fails above `free_a1_ocpus` / `free_a1_memory_gbs` |
| Block storage | 200 GB for every boot and block volume of the tenancy | the 50 GB boot volume per node |
| Load balancer | 1 flexible (10 Mbps) | not managed here |

The nodes and the `oci` stack's VMs draw on the **same** Arm allowance. Run one or the
other on the cores, or split them: a 1-OCPU node here and a 1-OCPU VM there. The Arm
capacity shortage that hits VMs ("Out of host capacity") hits node pools too; retry later.

## Usage

```bash
freelunch init oke
cp .freelunch/oke/terraform.tfvars.example .freelunch/oke/terraform.tfvars   # region, tenancy, SSH key
freelunch plan oke
freelunch apply oke
```

`apply` prints the `cluster` output with a `kubeconfig_command`; run it, then:

```bash
kubectl get nodes
```

freelunch doesn't deploy apps to the cluster. Use `kubectl apply`, Helm, or Argo CD. Without a
load balancer in front, expose an app with a `NodePort` and a Cloudflare Tunnel run as a
Deployment in the cluster, or use the free load balancer with a `Service` of type
`LoadBalancer`.

## Notes

- The API endpoint is public on 6443; restrict it with `api_source_cidrs`.
- The stack makes its own VCN with one public subnet for the API, the nodes and the load
  balancer. A production cluster would split them.
- Not yet run against a real tenancy: the first `apply` is the test.
