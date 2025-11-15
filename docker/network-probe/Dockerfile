# syntax=docker/dockerfile:1.7
FROM cgr.dev/chainguard/bash:latest@sha256:bb7561cfec779d33f02b126f9623c09c2b00ab94c7ad8a082a965d35cf1aaba9

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data network probe helper"

RUN apk add --no-cache iproute2 gawk && \
    mkdir -p /opt/core_data/scripts /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
COPY scripts/network_probe.sh /opt/core_data/scripts/network_probe.sh
RUN chmod 755 /opt/core_data/scripts/network_probe.sh

ENTRYPOINT ["/opt/core_data/scripts/network_probe.sh"]
