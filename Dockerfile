# freelunch runner: OpenTofu, the few tools the CLI uses, and the freelunch code itself.
#   docker run --rm -it -v "$PWD:/project" ghcr.io/freelunch-sh/freelunch:0.1.0 <command>
# Release images are built for amd64 and arm64 by .github/workflows/release.yml.
FROM debian:trixie-slim

ARG TOFU_VERSION=1.12.7

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash ca-certificates curl git jq openssh-client unzip \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    zip="tofu_${TOFU_VERSION}_linux_${arch}.zip"; \
    base="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}"; \
    cd /tmp; \
    curl -fsSLO "${base}/${zip}"; \
    curl -fsSLO "${base}/tofu_${TOFU_VERSION}_SHA256SUMS"; \
    grep " ${zip}\$" "tofu_${TOFU_VERSION}_SHA256SUMS" | sha256sum -c -; \
    unzip -j "${zip}" tofu -d /usr/local/bin; \
    rm -f "${zip}" "tofu_${TOFU_VERSION}_SHA256SUMS"; \
    tofu version

# No plugin cache here on purpose: in a project, providers are installed into
# .freelunch/<stack>/.terraform, which outlives the container.
ENV FREELUNCH_TF=tofu

COPY . /opt/freelunch
# The release's tag, so a project pinned to it runs the code here instead of downloading it
ARG FREELUNCH_VERSION=""
RUN if [ -n "$FREELUNCH_VERSION" ]; then echo "$FREELUNCH_VERSION" > /opt/freelunch/.version; fi

# The project is mounted here; the CLI finds its .freelunch/ folder from the working directory.
WORKDIR /project
ENTRYPOINT ["/opt/freelunch/bin/freelunch"]
CMD ["help"]
