# The provider takes its token as an argument, not from the environment, so it comes in as the
# input variable api_token: export TF_VAR_api_token (or put it in .freelunch/.env).
provider "axiom" {
  api_token = var.api_token
}
