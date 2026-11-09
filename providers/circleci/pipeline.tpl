# Written by freelunch ci init circleci. Runs freelunch in its runner image, with this project's
# state and secrets, when a pipeline is triggered by hand or by a schedule: it never runs on a push.
#
# - Project Settings > Environment Variables: FREELUNCH_BUNDLE, with the output of
#   freelunch ci secrets --print.
# - Trigger it from Project > Trigger Pipeline (or the API), with the parameter freelunch-run set to
#   the command (up, status, ...). For a wait for capacity (freelunch ci wait), add a scheduled
#   trigger every 30 minutes with freelunch-run set to "ci resume", and remove it when the wait is over.
# The image has OpenTofu, so the project has to use OpenTofu too.
version: 2.1

parameters:
  freelunch-run:
    type: string
    default: up

jobs:
  freelunch:
    docker:
      - image: @IMAGE@
    steps:
      - checkout
      - run:
          name: restore
          command: /opt/freelunch/bin/freelunch ci restore
      - run:
          name: freelunch
          command: /opt/freelunch/bin/freelunch << pipeline.parameters.freelunch-run >>

workflows:
  freelunch:
    when:
      or:
        - equal: [api, << pipeline.trigger_source >>]
        - equal: [scheduled_pipeline, << pipeline.trigger_source >>]
    jobs:
      - freelunch
