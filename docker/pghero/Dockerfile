# syntax=docker/dockerfile:1.7
FROM ankane/pghero:4.4.2

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data PgHero with hardened entrypoint"

RUN mkdir -p /opt/core_data/scripts /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
COPY scripts/pghero_entrypoint.sh /opt/core_data/scripts/pghero_entrypoint.sh
RUN chmod 755 /opt/core_data/scripts/pghero_entrypoint.sh

ENTRYPOINT ["/bin/sh", "/opt/core_data/scripts/pghero_entrypoint.sh"]
