# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data PgBouncer with hardened entrypoint"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      pgbouncer \
      bash \
      netcat-openbsd \
      postgresql-client \
      ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -p /opt/core_data/bin /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md

COPY pgbouncer/entrypoint.sh /opt/core_data/bin/pgbouncer-entrypoint.sh
RUN chmod 755 /opt/core_data/bin/pgbouncer-entrypoint.sh

ENTRYPOINT ["/opt/core_data/bin/pgbouncer-entrypoint.sh"]
