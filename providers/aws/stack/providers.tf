# Credentials come from the standard AWS chain: AWS_PROFILE / ~/.aws/config (including
# `aws sso login`), or AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY.
provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = { "managed-by" = "freelunch" }
  }
}
