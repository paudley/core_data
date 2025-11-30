# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim

LABEL org.opencontainers.image.source="https://github.com/paudley/core_data" \
      org.opencontainers.image.description="Core Data PgBouncer with hardened entrypoint"

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies and add PGDG repository for PgBouncer 1.21+
# PGDG provides latest PgBouncer with max_prepared_statements support (requires 1.21+)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      gnupg \
      lsb-release && \
    # Add PostgreSQL APT repository for latest PgBouncer
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
      https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      pgbouncer \
      netcat-openbsd \
      procps \
      postgresql-client \
      openssl && \
    # Cleanup
    apt-get purge -y --auto-remove curl gnupg lsb-release && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    mkdir -p /opt/core_data/bin /opt/core_data/docs && chmod 755 /opt/core_data
COPY README.md SECURITY.md /opt/core_data/docs/
RUN cp /opt/core_data/docs/README.md /README.md && cp /opt/core_data/docs/SECURITY.md /SECURITY.md

# Add secrets group and add postgres user to it for reading shared secrets
ARG SECRETS_GID=65532
RUN groupadd --gid "${SECRETS_GID}" secrets && \
    usermod --append --groups secrets postgres

COPY pgbouncer/entrypoint.sh /opt/core_data/bin/pgbouncer-entrypoint.sh
RUN chmod 755 /opt/core_data/bin/pgbouncer-entrypoint.sh

ENTRYPOINT ["/opt/core_data/bin/pgbouncer-entrypoint.sh"]
