# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# syntax=docker/dockerfile:1.7
ARG PG_VERSION=17
ARG AGE_VERSION=master
FROM postgres:${PG_VERSION}-bookworm

LABEL maintainer="core_data team"

ARG PG_VERSION
ARG AGE_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    AGE_VERSION=${AGE_VERSION}

# Install dependencies, extensions, and tooling required by the platform
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
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
      postgresql-${PG_MAJOR}-partman \
      postgresql-${PG_MAJOR}-repack \
      postgresql-${PG_MAJOR}-pgtap \
      postgresql-contrib \
      pgbadger \
      pgbackrest; \
    rm -rf /var/lib/apt/lists/*

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
VOLUME ["/var/lib/postgresql/data", "/var/lib/pgbackrest"]

HEALTHCHECK --start-period=30s --interval=10s --timeout=5s --retries=5 \
    CMD pg_isready -U "$${POSTGRES_USER:-postgres}" || exit 1
