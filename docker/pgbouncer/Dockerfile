# syntax=docker/dockerfile:1.7
FROM bitnamilegacy/pgbouncer:1.24.1

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data PgBouncer with hardened entrypoint"

RUN apk add --no-cache bash netcat-openbsd postgresql16-client && \
    mkdir -p /opt/core_data/bin /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md

COPY pgbouncer/entrypoint.sh /opt/core_data/bin/pgbouncer-entrypoint.sh
RUN chmod 755 /opt/core_data/bin/pgbouncer-entrypoint.sh

ENTRYPOINT ["/opt/core_data/bin/pgbouncer-entrypoint.sh"]
