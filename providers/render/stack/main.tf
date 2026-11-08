# Render has no Terraform resources freelunch needs: `freelunch apply render` checks the
# workspace through Render's API, `freelunch deploy` makes a web service per app from its
# image, and `freelunch destroy render` deletes them again. This stack declares the target:
# which workspace and region, and refuses a paid plan.
#
# The free plan gives a workspace 750 instance-hours a month, enough for one service awake
# all month or several that sleep. A free web service sleeps after 15 minutes without a
# request and takes about a minute to wake. It is public at <service>.onrender.com.

locals {
  limits = yamldecode(file("${path.module}/../provider.yaml")).limits
}

resource "terraform_data" "target" {
  input = {
    owner  = var.owner_id
    region = var.region
    plan   = var.plan
  }

  lifecycle {
    precondition {
      condition     = var.acknowledge_billable_resources || contains(local.limits.plans, var.plan)
      error_message = "Only the plan ${join(" and ", local.limits.plans)} is free on Render, not ${var.plan}. Set acknowledge_billable_resources = true to use it on a paid plan."
    }
  }
}
