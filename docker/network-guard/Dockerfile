# syntax=docker/dockerfile:1.7
ARG WOLFI_BASE_TAG=latest
FROM cgr.dev/chainguard/wolfi-base:${WOLFI_BASE_TAG}

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data network guard helper"

RUN apk add --no-cache bash iproute2 iptables ip6tables ipset coreutils && \
    mkdir -p /opt/core_data/scripts /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
COPY scripts/network_guard.sh /opt/core_data/scripts/network_guard.sh
RUN chmod 755 /opt/core_data/scripts/network_guard.sh

ENTRYPOINT ["/opt/core_data/scripts/network_guard.sh"]
