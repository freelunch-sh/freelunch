# Written by freelunch ci init codeberg. Runs freelunch in its runner image, with this project's
# state and secrets, from Actions > freelunch > Run workflow (Forgejo Actions; it never runs on a push).
#
# - Repository Settings > Actions > Secrets: FREELUNCH_BUNDLE, with the output of
#   freelunch ci secrets --print.
# - For a wait for capacity (freelunch ci wait), add a schedule: trigger and run the workflow with
#   run set to "ci resume" every 30 minutes, and remove it when the wait is over.
# Codeberg's runners take the label docker. The image has OpenTofu, so the project has to use OpenTofu too.
name: freelunch

on:
  workflow_dispatch:
    inputs:
      run:
        description: The freelunch command to run
        default: up

concurrency:
  group: freelunch

jobs:
  freelunch:
    runs-on: docker
    container:
      image: @IMAGE@
    steps:
      - uses: https://code.forgejo.org/actions/checkout@v4
      - name: restore
        run: /opt/freelunch/bin/freelunch ci restore
        env:
          FREELUNCH_BUNDLE: ${{ secrets.FREELUNCH_BUNDLE }}
      - name: freelunch
        # the input goes through the environment, never into the script text
        run: |
          read -ra args <<< "$FREELUNCH_RUN"
          /opt/freelunch/bin/freelunch "${args[@]}"
        env:
          FREELUNCH_BUNDLE: ${{ secrets.FREELUNCH_BUNDLE }}
          FREELUNCH_RUN: ${{ inputs.run }}
