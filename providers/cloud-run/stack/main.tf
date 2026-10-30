# Cloud Run services have no Terraform resources freelunch needs: `freelunch deploy` makes a
# service per app through the Cloud Run Admin API, and `freelunch destroy cloud-run` deletes
# the ones it made. This stack declares the target: which Google Cloud project and region,
# and how big each instance is. It runs with request-based billing and no minimum
# instances, which is what the free grant covers.

resource "terraform_data" "target" {
  input = {
    project = var.project_id
    region  = var.region
    cpu     = var.cpu
    memory  = var.memory
    max     = var.max_instances
  }
}
