# The API key comes from TAILSCALE_API_KEY in the environment (or .freelunch/.env), and the
# tailnet from TAILSCALE_TAILNET or `tailnet` below. "-" is the tailnet of the key.
provider "tailscale" {
  tailnet = var.tailnet
}
