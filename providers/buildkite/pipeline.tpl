# Written by freelunch ci init buildkite. Runs freelunch in its runner image, with this project's
# state and secrets, in a build you start by hand (New Build, with FREELUNCH_RUN in its environment,
# default up) or by a schedule. It needs an agent that can run Docker.
#
# - Pipeline settings > Environment Variables (or a Buildkite secret): FREELUNCH_BUNDLE, with the
#   output of freelunch ci secrets --print.
# - For a wait for capacity (freelunch ci wait), add a schedule every 30 minutes with the
#   environment FREELUNCH_RUN set to "ci resume", and remove it when the wait is over.
# The image has OpenTofu, so the project has to use OpenTofu too.
steps:
  - label: freelunch
    command:
      - /opt/freelunch/bin/freelunch ci restore
      - /opt/freelunch/bin/freelunch $${FREELUNCH_RUN:-up}
    concurrency: 1
    concurrency_group: freelunch
    plugins:
      - docker#v5.11.0:
          image: @IMAGE@
          entrypoint: ""
          shell: ["/bin/sh", "-e", "-c"]
          environment:
            - FREELUNCH_BUNDLE
            - FREELUNCH_RUN
