# Written by freelunch ci init bitbucket. Runs freelunch in its runner image, with this project's
# state and secrets, from Pipelines > Run pipeline > Custom: freelunch (it never runs on a push).
#
# - Repository settings > Pipelines > Repository variables: FREELUNCH_BUNDLE, secured, with the
#   output of freelunch ci secrets --print.
# - The variable FREELUNCH_RUN is the command (up, status, ...). For a wait for capacity
#   (freelunch ci wait), add a schedule (Pipelines > Schedules) for the custom pipeline with
#   FREELUNCH_RUN set to "ci resume", every 30 minutes, and remove it when the wait is over.
# The image has OpenTofu, so the project has to use OpenTofu too.
image: @IMAGE@

pipelines:
  custom:
    freelunch:
      - variables:
          - name: FREELUNCH_RUN
            default: up
      - step:
          name: freelunch
          script:
            - /opt/freelunch/bin/freelunch ci restore
            - /opt/freelunch/bin/freelunch $FREELUNCH_RUN
