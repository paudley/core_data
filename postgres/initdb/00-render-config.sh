#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

TEMPLATE_DIR="/opt/core_data/conf"
SENTINEL="${PGDATA}/.core_data_config_rendered"
PGBACKREST_CONF_PATH="${PGDATA}/pgbackrest.conf"

: "${POSTGRES_LISTEN_ADDRESSES:=0.0.0.0}"
: "${POSTGRES_MAX_CONNECTIONS:=200}"
: "${PG_SHARED_BUFFERS:=1GB}"
: "${PG_EFFECTIVE_CACHE_SIZE:=3GB}"
: "${PG_WORK_MEM:=16MB}"
: "${PG_MAINTENANCE_WORK_MEM:=256MB}"
: "${PG_RANDOM_PAGE_COST:=1.1}"
: "${PG_EFFECTIVE_IO_CONCURRENCY:=200}"
: "${PG_MAX_WAL_SIZE:=2GB}"
: "${PG_MIN_WAL_SIZE:=1GB}"
: "${PG_WAL_KEEP_SIZE:=2GB}"
: "${PG_MAX_WAL_SENDERS:=10}"
: "${PG_CHECKPOINT_COMPLETION_TARGET:=0.9}"
: "${PG_LOG_MIN_DURATION_STATEMENT:=500}"
: "${POSTGRES_SSL_ENABLED:=on}"
: "${POSTGRES_SSL_CERT_FILE:=${PGDATA}/tls/server.crt}"
: "${POSTGRES_SSL_KEY_FILE:=${PGDATA}/tls/server.key}"
: "${POSTGRES_SSL_SELF_SIGNED_SUBJECT:=/CN=core_data_postgres}"
: "${POSTGRES_SSL_SELF_SIGNED_DAYS:=730}"

export \
  POSTGRES_LISTEN_ADDRESSES \
  POSTGRES_MAX_CONNECTIONS \
  PG_SHARED_BUFFERS \
  PG_EFFECTIVE_CACHE_SIZE \
  PG_WORK_MEM \
  PG_MAINTENANCE_WORK_MEM \
  PG_RANDOM_PAGE_COST \
  PG_EFFECTIVE_IO_CONCURRENCY \
  PG_MAX_WAL_SIZE \
  PG_MIN_WAL_SIZE \
  PG_WAL_KEEP_SIZE \
  PG_MAX_WAL_SENDERS \
  PG_CHECKPOINT_COMPLETION_TARGET \
  PG_LOG_MIN_DURATION_STATEMENT \
  POSTGRES_SSL_ENABLED \
  POSTGRES_SSL_CERT_FILE \
  POSTGRES_SSL_KEY_FILE

mkdir -p "${PGDATA}"

if [[ -f "${SENTINEL}" ]]; then
  echo "[core_data] Configuration already rendered; skipping." >&2
  exit 0
fi

if [[ "${POSTGRES_SSL_ENABLED}" == "on" ]]; then
  CERT_DIR=$(dirname "${POSTGRES_SSL_CERT_FILE}")
  KEY_DIR=$(dirname "${POSTGRES_SSL_KEY_FILE}")
  mkdir -p "${CERT_DIR}" "${KEY_DIR}"
  if [[ ! -f "${POSTGRES_SSL_CERT_FILE}" || ! -f "${POSTGRES_SSL_KEY_FILE}" ]]; then
    echo "[core_data] Generating self-signed TLS certificate for PostgreSQL." >&2
    if ! command -v openssl >/dev/null 2>&1; then
      echo "[core_data] ERROR: openssl not available; cannot create TLS assets." >&2
      exit 1
    fi
    openssl req -x509 -nodes -newkey rsa:4096 \
      -keyout "${POSTGRES_SSL_KEY_FILE}" \
      -out "${POSTGRES_SSL_CERT_FILE}" \
      -days "${POSTGRES_SSL_SELF_SIGNED_DAYS}" \
      -subj "${POSTGRES_SSL_SELF_SIGNED_SUBJECT}" >/dev/null 2>&1
    chmod 600 "${POSTGRES_SSL_KEY_FILE}"
    chmod 644 "${POSTGRES_SSL_CERT_FILE}"
  fi
fi

if command -v envsubst >/dev/null 2>&1; then
  envsubst < "${TEMPLATE_DIR}/postgresql.conf.tpl" > "${PGDATA}/postgresql.conf"
  envsubst < "${TEMPLATE_DIR}/pg_hba.conf.tpl" > "${PGDATA}/pg_hba.conf"
else
  echo "envsubst not installed inside container" >&2
  exit 1
fi

cat > "${PGBACKREST_CONF_PATH}" <<CONF
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=7
process-max=4
start-fast=y
log-level-console=info
archive-check=n

[main]
pg1-path=${PGDATA}
pg1-port=5432
CONF


echo "[core_data] Rendered PostgreSQL configs and pgBackRest configuration." >&2

pg_ctl -D "${PGDATA}" -m fast -w restart >/dev/null 2>&1 || {
  echo "[core_data] WARNING: pg_ctl restart failed during initialization." >&2
}

touch "${SENTINEL}"
