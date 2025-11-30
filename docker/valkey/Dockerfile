# syntax=docker/dockerfile:1.7
FROM valkey/valkey:9-alpine

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data ValKey with hardened entrypoint"

# Add secrets group and add valkey user to it for reading shared secrets
ARG SECRETS_GID=65532
RUN addgroup -g "${SECRETS_GID}" secrets && \
    addgroup valkey secrets

RUN mkdir -p /opt/core_data/bin /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md
COPY valkey/entrypoint.sh /opt/core_data/bin/valkey-entrypoint.sh
RUN chmod 755 /opt/core_data/bin/valkey-entrypoint.sh

ENTRYPOINT ["/opt/core_data/bin/valkey-entrypoint.sh"]
