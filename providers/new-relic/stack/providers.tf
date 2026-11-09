# The user API key comes from NEW_RELIC_API_KEY in the environment (or .freelunch/.env); the account and
# region are the variables below.
provider "newrelic" {
  account_id = var.account_id
  region     = var.region
}
