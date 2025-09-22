#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

log() {
  printf '[healthcheck] %s\n' "$1" >&2
}

PGUSER=${POSTGRES_SUPERUSER:-${POSTGRES_USER:-postgres}}
PGDATABASE=${POSTGRES_DB:-postgres}
PGHOST=${POSTGRES_HEALTHCHECK_HOST:-${PGHOST:-/var/run/postgresql}}
PGPORT=${POSTGRES_PORT:-5432}
PGSSLMODE=${POSTGRES_HEALTHCHECK_SSLMODE:-require}

export PGUSER PGDATABASE PGHOST PGPORT PGSSLMODE

if ! pg_isready -q; then
  log "pg_isready failed"
  exit 1
fi

if ! psql -Atqc 'SELECT 1;' >/dev/null 2>&1; then
  log 'failed to execute SELECT 1'
  exit 1
fi

if [[ -n ${CORE_DATA_HEALTHCHECK_MAX_REPLICATION_LAG:-} ]]; then
  lag_threshold=${CORE_DATA_HEALTHCHECK_MAX_REPLICATION_LAG}
  if ! [[ ${lag_threshold} =~ ^[0-9]+$ ]]; then
    log "invalid CORE_DATA_HEALTHCHECK_MAX_REPLICATION_LAG=${lag_threshold}"
    exit 1
  fi
  replication_lag=$(psql -Atqc "SELECT COALESCE(MAX(EXTRACT(EPOCH FROM GREATEST(flush_lag, write_lag, replay_lag))), 0) FROM pg_stat_replication;" || echo "0")
  replication_lag=${replication_lag:-0}
  replication_lag_int=$(printf '%.0f' "${replication_lag}")
  if (( replication_lag_int > lag_threshold )); then
    log "replication lag ${replication_lag_int}s exceeds threshold ${lag_threshold}s"
    exit 1
  fi
fi

exit 0
