# Written by freelunch ci init azure-devops. Runs freelunch in its runner image, with this
# project's state and secrets, when you run the pipeline (Run pipeline, and choose the command).
# It never runs on a push or a pull request.
#
# - Pipelines > Library, or the pipeline's Variables: FREELUNCH_BUNDLE, kept secret, with the
#   output of freelunch ci secrets --print. A secret variable has to be passed to a step on purpose,
#   as the env: lines below do.
# - For a wait for capacity (freelunch ci wait), add a scheduled run every 30 minutes with the
#   parameter run set to "ci resume", and remove it when the wait is over.
# The image has OpenTofu, so the project has to use OpenTofu too.
trigger: none
pr: none

parameters:
  - name: run
    displayName: The freelunch command to run
    type: string
    default: up

pool:
  vmImage: ubuntu-24.04

container:
  image: @IMAGE@

steps:
  - script: /opt/freelunch/bin/freelunch ci restore
    displayName: restore
    env:
      FREELUNCH_BUNDLE: $(FREELUNCH_BUNDLE)
  - script: /opt/freelunch/bin/freelunch ${{ parameters.run }}
    displayName: freelunch
    env:
      FREELUNCH_BUNDLE: $(FREELUNCH_BUNDLE)
