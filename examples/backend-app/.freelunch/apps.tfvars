# Apps that `freelunch deploy` runs on your hosts. Paths are relative to this folder.
# Host names are <provider>-<instance>; `freelunch inventory` lists them.

apps = {
  api = {
    host    = "oci-main"
    compose = "../compose.yaml"

    # Secrets for the app, copied to the host as .env next to the compose file.
    # Keep the file in this folder: *.env files are git-ignored.
    # env_file = "api.env"
  }
}

# For a private image, log in before pulling. The token is read from GHCR_TOKEN in
# your environment or in .freelunch/.env.
# registries = {
#   "ghcr.io" = { username = "your-github-user", password_env = "GHCR_TOKEN" }
# }
