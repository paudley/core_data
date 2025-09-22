#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ -z "${POSTGRES_PASSWORD:-}" && -n "${POSTGRES_PASSWORD_FILE:-}" && -r "${POSTGRES_PASSWORD_FILE}" ]]; then
  POSTGRES_PASSWORD=$(<"${POSTGRES_PASSWORD_FILE}")
fi

if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  export PGPASSWORD="${POSTGRES_PASSWORD}"
fi

until psql --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" --command "SELECT 1;" >/dev/null 2>&1; do
  sleep 1
done

# shellcheck disable=SC1091
# shellcheck source=/opt/core_data/scripts/lib/extensions_list.sh
source /opt/core_data/scripts/lib/extensions_list.sh
# shellcheck disable=SC1091
# shellcheck source=/opt/core_data/scripts/lib/extensions_helpers.sh
source /opt/core_data/scripts/lib/extensions_helpers.sh

EXTENSIONS=("${CORE_EXTENSION_LIST[@]}")

DOLLAR='$'

mapfile -t target_dbs < <(psql --tuples-only --no-align --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" --command "SELECT datname FROM pg_database WHERE datistemplate = false;")

configure_database() {
  local db="$1"
  echo "[core_data] Enabling extensions and automation in database '${db}'." >&2
  for ext in "${EXTENSIONS[@]}"; do
    if [[ "${ext}" == "pg_cron" && "${db}" != "postgres" ]]; then
      continue
    fi
    if [[ "${ext}" == "pg_partman" ]]; then
      local pg_partman_sql
      pg_partman_sql=$(generate_pg_partman_sql)
      if ! psql --set ON_ERROR_STOP=on --username "${POSTGRES_USER}" --dbname "${db}" --command "${pg_partman_sql}"; then
        echo "[core_data] WARNING: failed to install extension '${ext}' in database '${db}'." >&2
      fi
      continue
    fi
    if ! psql --set ON_ERROR_STOP=on --username "${POSTGRES_USER}" --dbname "${db}" --command "CREATE EXTENSION IF NOT EXISTS \"${ext}\";"; then
      if [[ "${ext}" == "pgaudit" ]]; then
        echo "[core_data] WARNING: pgaudit extension requires shared_preload_libraries; run CREATE EXTENSION pgaudit; after restart." >&2
      else
        echo "[core_data] WARNING: failed to install extension '${ext}' in database '${db}'." >&2
      fi
    fi
  done

  psql --set ON_ERROR_STOP=on --username "${POSTGRES_USER}" --dbname "${db}" <<SQL
CREATE SCHEMA IF NOT EXISTS core_data_admin AUTHORIZATION ${POSTGRES_USER};

CREATE OR REPLACE FUNCTION core_data_admin.refresh_pg_squeeze_targets()
RETURNS void
LANGUAGE plpgsql
AS ${DOLLAR}${DOLLAR}
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT n.nspname AS schema_name,
           c.relname AS table_name
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE c.relkind IN ('r','m')
       AND n.nspname NOT LIKE 'pg_%'
       AND n.nspname <> 'information_schema'
       AND n.nspname NOT IN (
         'ag_catalog',
         'cron',
         'squeeze',
         'topology',
         'tiger',
         'tiger_data',
         'partman',
         'address_standardizer',
         'address_standardizer_data_us',
         'asyncq'
       )
  LOOP
    PERFORM squeeze.squeeze_table(rec.schema_name, rec.table_name);
  END LOOP;
END;
${DOLLAR}${DOLLAR};

SELECT core_data_admin.refresh_pg_squeeze_targets();
SQL
}

schedule_pg_squeeze_job() {
  local db="$1"
  local job_name="core_data_pgsqueeze_${db}"
  psql --set ON_ERROR_STOP=on --username "${POSTGRES_USER}" --dbname "postgres" <<SQL
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = '${job_name}';
SELECT cron.schedule_in_database('${job_name}', '15 3 * * *', \$\$SELECT core_data_admin.refresh_pg_squeeze_targets();\$\$, '${db}');
SQL
}

for db in "${target_dbs[@]}"; do
  configure_database "${db}"
  schedule_pg_squeeze_job "${db}"
done

# Reset pg_stat_statements nightly to preserve meaningful comparisons.
psql --set ON_ERROR_STOP=on --username "${POSTGRES_USER}" --dbname "postgres" <<'SQL'
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'core_data_pgstat_reset';
SELECT cron.schedule('core_data_pgstat_reset', '0 4 * * *', $$SELECT pg_stat_statements_reset();$$);
SQL

# Nightly vacuum analyze with SKIP_LOCKED and parallel workers to keep stats fresh safely.
psql --set ON_ERROR_STOP=on --username "${POSTGRES_USER}" --dbname "postgres" <<'SQL'
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'core_data_vacuum_analyze';
SELECT cron.schedule('core_data_vacuum_analyze', '30 2 * * *', $$VACUUM (ANALYZE, SKIP_LOCKED, PARALLEL 4);$$);
SQL

# Ensure template1 ships with extensions and helper functions so new databases inherit them.
configure_database "template1"
