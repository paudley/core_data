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
  local log_path
  log_path="/backups/pg_repack-$(date +%Y%m%d%H%M%S).log"
  if [[ -z ${table_list} ]]; then
    echo "[compact] ERROR: pg_repack requires --tables schema.table[,schema.table...]" >&2
    exit 1
  fi
  local script_path
  script_path="/tmp/core_data_pg_repack.sh"
  local repack_script
  repack_script=$(cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

: "${TABLE_LIST:?TABLE_LIST not set}"
: "${LOG_PATH:?LOG_PATH not set}"

IFS=',' read -r -a tables <<<"${TABLE_LIST}"
mapfile -t databases < <(psql --tuples-only --no-align --dbname "${POSTGRES_DB:-postgres}" --command "SELECT datname FROM pg_database WHERE datistemplate = false;")
mkdir -p "$(dirname "${LOG_PATH}")"
: > "${LOG_PATH}"

for table in "${tables[@]}"; do
  [[ -z "${table}" ]] && continue
  target_db=""
  for db in "${databases[@]}"; do
    [[ -z "${db}" ]] && continue
    exists=$(psql --tuples-only --no-align --dbname "${db}" --command "SELECT to_regclass(\$\$${table}\$\$) IS NOT NULL;")
    exists=${exists//[[:space:]]/}
    exists_lower=${exists,,}
    if [[ "${exists_lower}" == "t" || "${exists_lower}" == "true" ]]; then
      target_db="${db}"
      break
    fi
  done
  if [[ -z "${target_db}" ]]; then
    echo "[compact] ERROR: table ${table} not found in any database" >&2
    exit 1
  fi
  echo "[compact] Running pg_repack for ${target_db}.${table}" >&2
  pg_repack --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${target_db}" --no-superuser-check --table "${table}" | tee -a "${LOG_PATH}"
done

echo "[compact] pg_repack output stored at ${LOG_PATH}" >&2
EOS
)
  local encoded_script
  encoded_script=$(printf '%s' "${repack_script}" | base64 | tr -d '\n')

  compose_exec bash -lc "echo '${encoded_script}' | base64 -d > '${script_path}'"

  compose_exec env \
    PGHOST="${POSTGRES_HOST:-/var/run/postgresql}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    TABLE_LIST="${table_list}" \
    LOG_PATH="${log_path}" \
    bash "${script_path}"

  compose_exec bash -lc "rm -f '${script_path}'"
  audit_pg_squeeze
}

run_vacuum_full() {
  ensure_env
  local scope=${1:-all}
  local log_path
  log_path=/backups/vacuum-full-$(date +%Y%m%d%H%M%S).log
  local host_target=${POSTGRES_HOST:-/var/run/postgresql}
  local password=${POSTGRES_SUPERUSER_PASSWORD:-}

  if [[ ${scope} == all ]]; then
    compose_exec env PGHOST="${host_target}" PGUSER="${POSTGRES_SUPERUSER:-postgres}" PGPASSWORD="${password}" \
      bash -lc "psql --dbname \"${POSTGRES_DB:-postgres}\" --command \"VACUUM (FULL, ANALYZE, VERBOSE);\" | tee '${log_path}'"
    echo "VACUUM FULL output stored at ${log_path}" >&2
    return
  fi

  local vacuum_script
  vacuum_script=$(cat <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

: "${TARGET_SCOPE:?TARGET_SCOPE not set}"
: "${LOG_PATH:?LOG_PATH not set}"

IFS=',' read -r -a tables <<<"${TARGET_SCOPE}"
mapfile -t databases < <(psql --tuples-only --no-align --dbname "${POSTGRES_DB:-postgres}" --command "SELECT datname FROM pg_database WHERE datistemplate = false;")
mkdir -p "$(dirname "${LOG_PATH}")"
: > "${LOG_PATH}"

for table in "${tables[@]}"; do
  table="${table}" # preserve literal spacing
  [[ -z "${table}" ]] && continue
  target_db=""
  for db in "${databases[@]}"; do
    [[ -z "${db}" ]] && continue
    exists=$(psql --tuples-only --no-align --dbname "${db}" --command "SELECT to_regclass(\$\$${table}\$\$) IS NOT NULL;")
    exists=${exists//[[:space:]]/}
    exists_lower=${exists,,}
    if [[ "${exists_lower}" == "t" || "${exists_lower}" == "true" ]]; then
      target_db="${db}"
      break
    fi
  done
  if [[ -z "${target_db}" ]]; then
    echo "[compact] ERROR: table ${table} not found in any database" >&2
    exit 1
  fi
  echo "[compact] Running VACUUM FULL for ${target_db}.${table}" >&2
  psql --dbname "${target_db}" --command "VACUUM (FULL, ANALYZE, VERBOSE) ${table};" | tee -a "${LOG_PATH}"
done

echo "VACUUM FULL output stored at ${LOG_PATH}" >&2
EOS
)

  local encoded_vacuum
  encoded_vacuum=$(printf '%s' "${vacuum_script}" | base64 | tr -d '\n')
  local script_path="/tmp/core_data_vacuum_full.sh"
  compose_exec bash -lc "echo '${encoded_vacuum}' | base64 -d > '${script_path}'"

  compose_exec env \
    PGHOST="${host_target}" \
    PGUSER="${POSTGRES_SUPERUSER:-postgres}" \
    PGPASSWORD="${password}" \
    TARGET_SCOPE="${scope}" \
    LOG_PATH="${log_path}" \
    bash "${script_path}"

  compose_exec bash -lc "rm -f '${script_path}'"
}
