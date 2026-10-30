# Apps that `freelunch up` and `freelunch deploy` run. Paths are relative to this folder.

# Where they may run, in order: `freelunch up` takes the first that runs the project already
# or has room to make it, and goes on to the next when one is out of capacity. Leave it out
# to use every stack you have set up, Oracle first.
# targets = ["oci", "northflank"]

apps = {
  api = {
    compose = "../compose.yaml"
    # Pin the app to one target instead (<provider>-<instance>; `freelunch inventory` lists them):
    # host = "oci-main"

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
