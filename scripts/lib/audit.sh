#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Observability and audit helpers for manage.sh and maintenance scripts.
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
LIB_AUDIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${LIB_AUDIT_DIR}/common.sh"

_snapshot_pg_stat_statements() {
  local target_path=$1
  local limit=${2:-100}
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
    --command "COPY (SELECT now() AS collected_at, datname, queryid, calls, total_exec_time, rows, shared_blks_hit, shared_blks_dirtied, shared_blks_written FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT ${limit}) TO '${target_path}' WITH (FORMAT csv, HEADER true);"
}

snapshot_pg_stat_statements() {
  ensure_env
  local target_path=${1:-}
  local limit=${2:-100}
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
      --csv --command "SELECT now() AS collected_at, datname, queryid, calls, total_exec_time, rows, shared_blks_hit, shared_blks_dirtied, shared_blks_written FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT ${limit};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  if _snapshot_pg_stat_statements "${target_path}" "${limit}"; then
    echo "pg_stat_statements snapshot written to ${target_path}" >&2
  else
    echo "[audit] WARNING: failed to capture pg_stat_statements snapshot" >&2
  fi
}

audit_roles() {
  ensure_env
  local target_path=${1:-}
  local query="SELECT rolname, rolsuper, rolreplication, rolcanlogin, CASE WHEN rolpassword IS NULL THEN 'missing' ELSE 'present' END AS password_status, COALESCE(rolvaliduntil::text, 'never') AS valid_until, CASE WHEN rolsuper AND rolpassword IS NULL THEN 'superuser without password' WHEN rolcanlogin AND rolpassword IS NULL THEN 'login role without password' WHEN rolvaliduntil IS NOT NULL AND rolvaliduntil < now() THEN 'password expired' ELSE 'ok' END AS finding FROM pg_roles WHERE rolname NOT LIKE 'pg_%' ORDER BY rolname;"
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
      --csv --command "${query}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
    --command "COPY (${query}) TO '${target_path}' WITH (FORMAT csv, HEADER true);"
  echo "Role audit written to ${target_path}" >&2
}

audit_extensions() {
  ensure_env
  local target_path=${1:-}
  local script="set -euo pipefail; export PGHOST='${POSTGRES_HOST}'; export PGPASSWORD='${POSTGRES_SUPERUSER_PASSWORD:-}'; dbs=\$(psql --username '${POSTGRES_SUPERUSER:-postgres}' --dbname '${POSTGRES_DB:-postgres}' --tuples-only --no-align --command \"SELECT datname FROM pg_database WHERE datistemplate = false\");"
  script+=" if [ -z \"\$dbs\" ]; then exit 0; fi;"
  if [[ -z ${target_path} ]]; then
    script+=" printf 'database,extension,extversion,default_version,status\\n';"
    script+=" for db in \$dbs; do psql --username '${POSTGRES_SUPERUSER:-postgres}' --dbname \"\$db\" --tuples-only --no-align --field-separator ',' --command \"SELECT '\$db' AS database, extname, extversion, (SELECT default_version FROM pg_available_extensions WHERE name = extname) AS default_version, CASE WHEN extversion = (SELECT default_version FROM pg_available_extensions WHERE name = extname) THEN 'ok' ELSE 'version drift' END AS status FROM pg_extension ORDER BY extname\"; done"
    compose_exec bash -lc "${script}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  script+=" printf 'database,extension,extversion,default_version,status\\n' > '${target_path}';"
  script+=" for db in \$dbs; do psql --username '${POSTGRES_SUPERUSER:-postgres}' --dbname \"\$db\" --tuples-only --no-align --field-separator ',' --command \"SELECT '\$db' AS database, extname, extversion, (SELECT default_version FROM pg_available_extensions WHERE name = extname) AS default_version, CASE WHEN extversion = (SELECT default_version FROM pg_available_extensions WHERE name = extname) THEN 'ok' ELSE 'version drift' END AS status FROM pg_extension ORDER BY extname\" >> '${target_path}'; done"
  compose_exec bash -lc "${script}"
  echo "Extension audit written to ${target_path}" >&2
}

audit_autovacuum() {
  ensure_env
  local target_path=${1:-}
  local dead_threshold=${2:-100000}
  local ratio_threshold=${3:-0.2}
  local query="SELECT now() AS collected_at, schemaname, relname, n_live_tup, n_dead_tup, ROUND(CASE WHEN n_live_tup > 0 THEN (n_dead_tup::numeric / n_live_tup) * 100 ELSE 0 END, 2) AS dead_pct, autovacuum_count, vacuum_count, COALESCE(last_autovacuum::text, 'never') AS last_autovacuum, COALESCE(last_analyze::text, 'never') AS last_analyze FROM pg_stat_user_tables WHERE n_dead_tup > ${dead_threshold} OR (n_live_tup > 0 AND (n_dead_tup::numeric / NULLIF(n_live_tup,0)) > ${ratio_threshold}) ORDER BY n_dead_tup DESC;"
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
      --csv --command "${query}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
    --command "COPY (${query}) TO '${target_path}' WITH (FORMAT csv, HEADER true);"
  echo "Autovacuum findings written to ${target_path}" >&2
}

audit_pg_cron() {
  ensure_env
  local target_path=${1:-}
  local query="SELECT jobid, jobname, schedule, nodename, database, active, COALESCE(last_run::text, 'never') AS last_run, COALESCE(next_run::text, 'unknown') AS next_run FROM cron.job ORDER BY jobname;"
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres --csv --command "${query}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres \
    --command "COPY (${query}) TO '${target_path}' WITH (FORMAT csv, HEADER true);"
  echo "pg_cron schedule written to ${target_path}" >&2
}

audit_pg_squeeze() {
  ensure_env
  local target_path=${1:-}
  local exists
  exists=$(compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres --tuples-only --no-align --command "SELECT to_regclass('squeeze.tables') IS NOT NULL;")
  if [[ ${exists,,} != "t" && ${exists,,} != "true" ]]; then
    if [[ -n ${target_path} ]]; then
      compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")' && echo 'squeeze.tables not available' > '${target_path}'"
    else
      echo "[audit] squeeze.tables not available; skipping." >&2
    fi
    return
  fi
  local query="SELECT * FROM squeeze.tables ORDER BY 1"
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres --csv --command "${query}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres \
    --command "COPY (${query}) TO '${target_path}' WITH (FORMAT csv, HEADER true);"
  echo "pg_squeeze activity written to ${target_path}" >&2
}

audit_index_bloat() {
  ensure_env
  local target_path=${1:-}
  local min_size_mb=${2:-10}
  local query="WITH stats AS (\n  SELECT i.schemaname, i.relname AS table_name, i.indexrelname AS index_name,\n         pg_relation_size(i.indexrelid) AS index_size_bytes,\n         pgstatindex(format('%I.%I', i.schemaname, i.indexrelname)) AS stat\n    FROM pg_stat_user_indexes i\n   WHERE pg_relation_size(i.indexrelid) >= ${min_size_mb} * 1024 * 1024\n)\nSELECT schemaname,\n       table_name,\n       index_name,\n       index_size_bytes,\n       ROUND((stat).avg_leaf_density::numeric, 2) AS avg_leaf_density,\n       ROUND(100 - (stat).avg_leaf_density::numeric, 2) AS estimated_bloat_pct,\n       ROUND((stat).leaf_fragmentation::numeric, 2) AS leaf_fragmentation\n  FROM stats\n ORDER BY estimated_bloat_pct DESC, index_size_bytes DESC;"
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
\copy (${query}) TO '${target_path}' WITH (FORMAT csv, HEADER true)
SQL
  echo "Index bloat report written to ${target_path}" >&2
}

audit_schema_snapshot() {
  ensure_env
  local target_path=${1:-}
  local query="SELECT table_schema, table_name, ordinal_position, column_name, data_type, is_nullable, column_default FROM information_schema.columns WHERE table_schema NOT IN ('information_schema','pg_catalog') ORDER BY table_schema, table_name, ordinal_position;"
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
\copy (${query}) TO '${target_path}' WITH (FORMAT csv, HEADER true)
SQL
  echo "Schema snapshot written to ${target_path}" >&2
}

audit_replication_lag() {
  ensure_env
  local target_path=${1:-}
  local lag_warn_seconds=${2:-300}
  local query="SELECT now() AS collected_at, application_name, client_addr, state, sync_state, write_lag, flush_lag, replay_lag, CASE WHEN write_lag IS NOT NULL AND write_lag > interval '${lag_warn_seconds} seconds' THEN 'lagging' ELSE 'ok' END AS status FROM pg_stat_replication ORDER BY application_name;"
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
      --csv --command "${query}"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
    --command "COPY (${query}) TO '${target_path}' WITH (FORMAT csv, HEADER true);"
  echo "Replication lag report written to ${target_path}" >&2
}

audit_security() {
  ensure_env
  local target_path=${1:-}
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<'SQL'
\pset format unaligned
\pset tuples_only on
SELECT '== HBA entries that use trust authentication =='::text;
SELECT format('%s %s %s %s', type, auth_method, COALESCE(user_name,'<all>'), COALESCE(address,'<all>'))
  FROM pg_hba_file_rules
 WHERE auth_method = 'trust';
SELECT '\n== Login roles without passwords =='::text;
SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolpassword IS NULL AND rolname NOT LIKE 'pg_%';
SELECT '\n== Roles with expired passwords =='::text;
SELECT rolname FROM pg_roles WHERE rolvaliduntil IS NOT NULL AND rolvaliduntil < now() AND rolname NOT LIKE 'pg_%';
SELECT '\n== Tables without row level security =='::text;
SELECT format('%s.%s', n.nspname, c.relname)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r'
   AND n.nspname NOT LIKE 'pg_%'
   AND n.nspname <> 'information_schema'
   AND NOT c.relrowsecurity;
SQL
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" <<SQL
\pset format unaligned
\pset tuples_only on
\o '${target_path}'
SELECT '== HBA entries that use trust authentication =='::text;
SELECT format('%s %s %s %s', type, auth_method, COALESCE(user_name,'<all>'), COALESCE(address,'<all>'))
  FROM pg_hba_file_rules
 WHERE auth_method = 'trust';
SELECT '\n== Login roles without passwords =='::text;
SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolpassword IS NULL AND rolname NOT LIKE 'pg_%';
SELECT '\n== Roles with expired passwords =='::text;
SELECT rolname FROM pg_roles WHERE rolvaliduntil IS NOT NULL AND rolvaliduntil < now() AND rolname NOT LIKE 'pg_%';
SELECT '\n== Tables without row level security =='::text;
SELECT format('%s.%s', n.nspname, c.relname)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r'
   AND n.nspname NOT LIKE 'pg_%'
   AND n.nspname <> 'information_schema'
   AND NOT c.relrowsecurity;
\o
SQL
  echo "Security audit written to ${target_path}" >&2
}


summarize_pgaudit_logs() {
  ensure_env
  local container_dir=$1
  compose_exec bash -lc "shopt -s nullglob; files=(\"${container_dir}\"/postgresql-*.csv); if [ \${#files[@]} -eq 0 ]; then exit 0; fi; rm -f \"${container_dir}/pgaudit_events.log\" \"${container_dir}/pgaudit_summary.csv\"; awk -F, 'NR==1 {for (i=1;i<=NF;i++){if ($i==\"message\") m=i; if ($i==\"user_name\") u=i}} NR>1 && m && index($m,\"pgaudit\") {user=(u? $u : \"unknown\"); events[user]++; print $m >> \"${container_dir}/pgaudit_events.log\"} END {if (length(events)) {print \"role,events\" > \"${container_dir}/pgaudit_summary.csv\"; for (role in events) print role \",\" events[role] >> \"${container_dir}/pgaudit_summary.csv\"}}' \"${container_dir}\"/postgresql-*.csv" || true
}

config_drift_report() {
  ensure_env
  local drift=0
  compose_exec bash -lc "envsubst < /opt/core_data/conf/postgresql.conf.tpl > /tmp/core_data_expected_postgresql.conf"
  compose_exec bash -lc "envsubst < /opt/core_data/conf/pg_hba.conf.tpl > /tmp/core_data_expected_pg_hba.conf"
  local conf_diff
  conf_diff=$(compose_exec bash -lc "diff -u /tmp/core_data_expected_postgresql.conf /var/lib/postgresql/data/postgresql.conf || true")
  if [[ -n ${conf_diff} ]]; then
    echo "[config-check] postgresql.conf drift detected:" >&2
    echo "${conf_diff}"
    drift=1
  else
    echo "[config-check] postgresql.conf matches rendered template." >&2
  fi
  local hba_diff
  hba_diff=$(compose_exec bash -lc "diff -u /tmp/core_data_expected_pg_hba.conf /var/lib/postgresql/data/pg_hba.conf || true")
  if [[ -n ${hba_diff} ]]; then
    echo "[config-check] pg_hba.conf drift detected:" >&2
    echo "${hba_diff}"
    drift=1
  else
    echo "[config-check] pg_hba.conf matches rendered template." >&2
  fi
  if [[ ${drift} -ne 0 ]]; then
    return 1
  fi
  return 0
}
