# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# syntax=docker/dockerfile:1.7
ARG PG_VERSION=17
ARG AGE_VERSION=master
ARG CORE_UID=1000
ARG CORE_GID=1000
ARG CORE_USERNAME=postgres
ARG CORE_GECOS="Core Data PostgreSQL Administrator"
ARG CORE_HOME=/home/postgres

FROM postgres:${PG_VERSION}-bookworm

LABEL maintainer="core_data team"

ARG PG_VERSION
ARG AGE_VERSION
ARG CORE_UID
ARG CORE_GID
ARG CORE_USERNAME
ARG CORE_GECOS
ARG CORE_HOME

ENV DEBIAN_FRONTEND=noninteractive \
    AGE_VERSION=${AGE_VERSION}

# Install dependencies, extensions, and tooling required by the platform
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg openssl; \
    echo "deb http://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgres.gpg; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential \
      cmake \
      git \
      gettext-base \
      bison \
      flex \
      libssl-dev \
      libxml2-dev \
      libxslt1-dev \
      libreadline-dev \
      postgresql-server-dev-${PG_MAJOR} \
      postgresql-${PG_MAJOR}-pgaudit \
      postgresql-${PG_MAJOR}-pgvector \
      postgresql-${PG_MAJOR}-postgis-3 \
      postgresql-${PG_MAJOR}-postgis-3-scripts \
      postgresql-${PG_MAJOR}-cron \
      postgresql-${PG_MAJOR}-pgrouting \
      postgresql-${PG_MAJOR}-partman \
      postgresql-${PG_MAJOR}-repack \
      postgresql-${PG_MAJOR}-hypopg \
      postgresql-${PG_MAJOR}-pgtap \
      postgresql-contrib \
      pgbadger \
    pgbackrest; \
    rm -rf /var/lib/apt/lists/*;

# Recreate postgres system user with operator-selected UID/GID and home
RUN set -eux; \
    groupmod --gid "${CORE_GID}" postgres; \
    usermod --uid "${CORE_UID}" --gid "${CORE_GID}" --home "${CORE_HOME}" --comment "${CORE_GECOS}" --shell /bin/bash postgres; \
    install -d -o "${CORE_UID}" -g "${CORE_GID}" "${CORE_HOME}"; \
    install -d -o "${CORE_UID}" -g "${CORE_GID}" /tmp/pgbackrest; \
    chown -R "${CORE_UID}:${CORE_GID}" /var/lib/postgresql /var/lib/pgbackrest;

# Build Apache AGE from source
RUN set -eux; \
    git clone --depth 1 --branch "${AGE_VERSION}" --single-branch https://github.com/apache/age.git /tmp/age; \
    cd /tmp/age; \
    make PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
    make install PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
    rm -rf /tmp/age

# Build pg_squeeze from source
RUN set -eux; \
    git clone --depth 1 https://github.com/cybertec-postgresql/pg_squeeze.git /tmp/pg_squeeze; \
    cd /tmp/pg_squeeze; \
    make PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
    make install PG_CONFIG="/usr/lib/postgresql/${PG_MAJOR}/bin/pg_config"; \
    rm -rf /tmp/pg_squeeze

# Copy configuration templates and initialization scripts
COPY postgres/conf /opt/core_data/conf
COPY postgres/initdb /docker-entrypoint-initdb.d
COPY postgres/tools /opt/core_data/tools
COPY scripts /opt/core_data/scripts

# Ensure scripts are executable
RUN chmod +x /docker-entrypoint-initdb.d/*.sh

# Provide default volume locations in the image
VOLUME ["/var/lib/postgresql/data", "/var/lib/pgbackrest", "/home/postgres"]

USER ${CORE_USERNAME}

HEALTHCHECK --start-period=30s --interval=10s --timeout=5s --retries=5 \
    CMD pg_isready -U "$${POSTGRES_USER:-postgres}" || exit 1
