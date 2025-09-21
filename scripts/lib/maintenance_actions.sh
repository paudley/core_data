#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Utilities for deep maintenance (pg_squeeze refresh, pg_repack, VACUUM FULL).
set -euo pipefail

LIB_MAINT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib/common.sh
source "${LIB_MAINT_DIR}/common.sh"
# shellcheck source=scripts/lib/audit.sh
source "${LIB_MAINT_DIR}/audit.sh"

refresh_pg_squeeze() {
  ensure_env
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
    --command "SELECT core_data_admin.refresh_pg_squeeze_targets();"
  audit_pg_squeeze
}

run_pg_repack() {
  ensure_env
  local table_list=${1:-}
  local log_path="/backups/pg_repack-$(date +%Y%m%d%H%M%S).log"
  if [[ -z ${table_list} ]]; then
    echo "[compact] ERROR: pg_repack requires --tables schema.table[,schema.table...]" >&2
    exit 1
  fi
  IFS=',' read -r -a tables <<<"${table_list}"
  local host_target=${POSTGRES_HOST:-/var/run/postgresql}
  local cmd=(pg_repack --username "${POSTGRES_SUPERUSER:-postgres}" --host "${host_target}" --dbname "${POSTGRES_DB:-postgres}" --no-superuser-check)
  for table in "${tables[@]}"; do
    cmd+=("--table=${table}")
  done
  compose_exec "${cmd[@]}" | tee "${log_path}"
  echo "pg_repack output stored at ${log_path}" >&2
  audit_pg_squeeze
}

run_vacuum_full() {
  ensure_env
  local scope=${1:-all}
  local output=/backups/vacuum-full-$(date +%Y%m%d%H%M%S).log
  if [[ ${scope} == all ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
      --command "VACUUM (FULL, ANALYZE, VERBOSE);" | tee "${output}"
  else
    IFS=',' read -r -a tables <<<"${scope}"
    for table in "${tables[@]}"; do
      compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
        psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
        --command "VACUUM (FULL, ANALYZE, VERBOSE) ${table};" | tee -a "${output}"
    done
  fi
  echo "VACUUM FULL output stored at ${output}" >&2
}
