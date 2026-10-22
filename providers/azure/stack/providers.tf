# Credentials: `az login` (Azure CLI), or a service principal through ARM_CLIENT_ID,
# ARM_CLIENT_SECRET and ARM_TENANT_ID. The Docker runner has no Azure CLI, so use the
# service principal variables in .env there.
provider "azurerm" {
  features {}

  subscription_id = var.subscription_id
}
