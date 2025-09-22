#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

PGBOUNCER_SERVICE_NAME=${PGBOUNCER_SERVICE_NAME:-pgbouncer}
PGBOUNCER_HOST=${PGBOUNCER_HOST:-pgbouncer}
PGBOUNCER_PORT=${PGBOUNCER_PORT:-6432}

cmd_pgbouncer_stats() {
  ensure_env
  load_secret_from_file PGBOUNCER_STATS_PASSWORD
  local password="${PGBOUNCER_STATS_PASSWORD:-}"
  local stats_user="${PGBOUNCER_STATS_USER:-pgbouncer_stats}"
  if [[ -z ${password} ]]; then
    echo "[pgbouncer] ERROR: PGBOUNCER_STATS_PASSWORD not provided (check secrets)." >&2
    exit 1
  fi
  compose_exec env \
    PGPASSWORD="${password}" \
    psql --host "${PGBOUNCER_HOST}" --port "${PGBOUNCER_PORT}" --username "${stats_user}" --dbname pgbouncer --tuples-only --command "SHOW STATS;"
}

cmd_pgbouncer_show_pools() {
  ensure_env
  load_secret_from_file PGBOUNCER_STATS_PASSWORD
  local password="${PGBOUNCER_STATS_PASSWORD:-}"
  local stats_user="${PGBOUNCER_STATS_USER:-pgbouncer_stats}"
  if [[ -z ${password} ]]; then
    echo "[pgbouncer] ERROR: PGBOUNCER_STATS_PASSWORD not provided (check secrets)." >&2
    exit 1
  fi
  compose_exec env \
    PGPASSWORD="${password}" \
    psql --host "${PGBOUNCER_HOST}" --port "${PGBOUNCER_PORT}" --username "${stats_user}" --dbname pgbouncer --tuples-only --command "SHOW POOLS;"
}
