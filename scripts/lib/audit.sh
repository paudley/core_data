#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2025 Blackcat Informatics® Inc.
# SPDX-License-Identifier: MIT

# Observability and audit helpers for manage.sh and maintenance scripts.
set -euo pipefail

LIB_AUDIT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
# shellcheck disable=SC1091
source "${LIB_AUDIT_DIR}/common.sh"

copy_query_to_file() {
  local db=$1
  local query=$2
  local target_path=$3

  local encoded
  encoded=$(printf '%s' "${query}" | base64 | tr -d '\n')
  compose_exec bash -lc "echo '${encoded}' | base64 -d > /tmp/core_data_audit.sql"
  compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    bash -lc "psql --username '${POSTGRES_SUPERUSER:-postgres}' --dbname '${db}' --csv --file /tmp/core_data_audit.sql > '${target_path}'"
  compose_exec bash -lc "rm -f /tmp/core_data_audit.sql"
}

_snapshot_pg_stat_statements() {
  local target_path=$1
  local limit=${2:-100}
query=$(cat <<SQL
SELECT now() AS collected_at,
SELECT now() AS collected_at,
       d.datname,
       s.queryid,
       s.calls,
       s.total_exec_time,
       s.rows,
       s.shared_blks_hit,
       s.shared_blks_dirtied,
       s.shared_blks_written
  FROM pg_stat_statements s
  JOIN pg_database d ON d.oid = s.dbid
 ORDER BY s.total_exec_time DESC
 LIMIT ${limit};
SQL
)
  copy_query_to_file "${POSTGRES_DB:-postgres}" "${query}" "${target_path}"
}

snapshot_pg_stat_statements() {
  ensure_env
  local target_path=${1:-}
  local limit=${2:-100}
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" \
      --csv --command "SELECT now() AS collected_at, d.datname, s.queryid, s.calls, s.total_exec_time, s.rows, s.shared_blks_hit, s.shared_blks_dirtied, s.shared_blks_written FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid ORDER BY s.total_exec_time DESC LIMIT ${limit};"
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
  local query
query=$(cat <<'SQL'
SELECT rolname,
       rolsuper,
       rolreplication,
       rolcanlogin,
       CASE WHEN rolpassword IS NULL THEN 'missing' ELSE 'present' END AS password_status,
       COALESCE(rolvaliduntil::text, 'never') AS valid_until,
       CASE
         WHEN rolsuper AND rolpassword IS NULL THEN 'superuser without password'
         WHEN rolcanlogin AND rolpassword IS NULL THEN 'login role without password'
         WHEN rolvaliduntil IS NOT NULL AND rolvaliduntil < now() THEN 'password expired'
         ELSE 'ok'
       END AS finding
 FROM pg_roles
WHERE rolname NOT LIKE 'pg_%'
ORDER BY rolname;
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  copy_query_to_file "${POSTGRES_DB:-postgres}" "${query}" "${target_path}"
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
  local query
query=$(cat <<SQL
SELECT now() AS collected_at,
       schemaname,
       relname,
       n_live_tup,
       n_dead_tup,
       ROUND(CASE WHEN n_live_tup > 0 THEN (n_dead_tup::numeric / n_live_tup) * 100 ELSE 0 END, 2) AS dead_pct,
       autovacuum_count,
       vacuum_count,
       COALESCE(last_autovacuum::text, 'never') AS last_autovacuum,
       COALESCE(last_analyze::text, 'never') AS last_analyze
 FROM pg_stat_user_tables
WHERE n_dead_tup > ${dead_threshold}
   OR (n_live_tup > 0 AND (n_dead_tup::numeric / NULLIF(n_live_tup,0)) > ${ratio_threshold})
 ORDER BY n_dead_tup DESC;
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  copy_query_to_file "${POSTGRES_DB:-postgres}" "${query}" "${target_path}"
  echo "Autovacuum findings written to ${target_path}" >&2
}

audit_pg_cron() {
  ensure_env
  local target_path=${1:-}
  local schema
  schema=$(compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
    psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres --tuples-only --no-align \
         --command "SELECT quote_ident(n.nspname)\
                      FROM pg_extension e\
                      JOIN pg_depend d\
                        ON d.refobjid = e.oid\
                       AND d.classid = 'pg_class'::regclass\
                       AND d.deptype = 'e'\
                      JOIN pg_class c ON c.oid = d.objid\
                      JOIN pg_namespace n ON n.oid = c.relnamespace\
                     WHERE e.extname = 'pg_cron'\
                       AND c.relname = 'job'\
                     LIMIT 1;")
  schema=${schema//$'\n'/}
  if [[ -z ${schema} ]]; then
    if [[ -n ${target_path} ]]; then
      compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")' && echo 'pg_cron extension not installed' > '${target_path}'"
    else
      echo "[audit] pg_cron extension not installed; skipping cron audit." >&2
    fi
    return
  fi

  local query
query=$(cat <<SQL
WITH latest AS (
  SELECT jobid,
         max(start_time) AS last_start
    FROM ${schema}.job_run_details
   GROUP BY jobid
)
SELECT j.jobid,
       j.jobname,
       j.schedule,
       j.command,
       j.database,
       j.username,
       j.active,
       l.last_start,
       d.end_time AS last_end,
       d.status AS last_status,
       d.return_message AS last_message
  FROM ${schema}.job j
  LEFT JOIN latest l ON l.jobid = j.jobid
  LEFT JOIN ${schema}.job_run_details d
         ON d.jobid = j.jobid AND l.last_start IS NOT NULL AND d.start_time = l.last_start
 ORDER BY j.jobname;
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  copy_query_to_file "postgres" "${query}" "${target_path}"
  echo "pg_cron schedule written to ${target_path}" >&2
}

audit_pg_buffercache() {
  ensure_env
  local target_path=${1:-}
  local limit=${2:-50}
  if ! [[ ${limit} =~ ^[0-9]+$ ]]; then
    echo "[audit] invalid limit '${limit}', falling back to 50" >&2
    limit=50
  fi
  local query
query=$(cat <<SQL
SELECT now() AS collected_at,
       n.nspname AS schema_name,
       c.relname AS relation_name,
       COUNT(*) AS buffers,
       ROUND(COUNT(*) * current_setting('block_size')::int / 1024.0 / 1024.0, 2) AS buffer_mb,
       ROUND((COUNT(*) * current_setting('block_size')::numeric) / pg_size_bytes(current_setting('shared_buffers')) * 100, 2) AS pct_of_cache,
       MAX(b.usagecount) AS max_usage_count,
       BOOL_OR(b.isdirty) AS has_dirty_buffers
  FROM pg_buffercache b
  JOIN pg_class c ON pg_relation_filenode(c.oid) = b.relfilenode
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE b.reldatabase IN (0, (SELECT oid FROM pg_database WHERE datname = current_database()))
   AND n.nspname NOT LIKE 'pg_%'
   AND n.nspname <> 'information_schema'
 GROUP BY n.nspname, c.relname
 ORDER BY buffers DESC
 LIMIT ${limit};
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  if copy_query_to_file "${POSTGRES_DB:-postgres}" "${query}" "${target_path}"; then
    echo "Buffer cache snapshot written to ${target_path}" >&2
  else
    echo "[audit] WARNING: failed to capture pg_buffercache snapshot" >&2
  fi
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
  local query
query=$(cat <<'SQL'
SELECT * FROM squeeze.tables ORDER BY 1;
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname postgres --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  copy_query_to_file "postgres" "${query}" "${target_path}"
  echo "pg_squeeze activity written to ${target_path}" >&2
}

audit_index_bloat() {
  ensure_env
  local target_path=${1:-}
  local min_size_mb=${2:-10}
  local query
query=$(cat <<SQL
WITH stats AS (
  SELECT i.schemaname,
         i.relname AS table_name,
         i.indexrelname AS index_name,
         pg_relation_size(i.indexrelid) AS index_size_bytes,
         pgstatindex(format('%I.%I', i.schemaname, i.indexrelname)) AS stat
  FROM pg_stat_user_indexes i
 WHERE pg_relation_size(i.indexrelid) >= ${min_size_mb} * 1024 * 1024
)
SELECT schemaname,
       table_name,
       index_name,
       index_size_bytes,
       ROUND((stat).avg_leaf_density::numeric, 2) AS avg_leaf_density,
       ROUND(100 - (stat).avg_leaf_density::numeric, 2) AS estimated_bloat_pct,
       ROUND((stat).leaf_fragmentation::numeric, 2) AS leaf_fragmentation
  FROM stats
 ORDER BY estimated_bloat_pct DESC, index_size_bytes DESC;
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  copy_query_to_file "${POSTGRES_DB:-postgres}" "${query}" "${target_path}"
  echo "Index bloat report written to ${target_path}" >&2
}

audit_schema_snapshot() {
  ensure_env
  local target_path=${1:-}
  local query
query=$(cat <<'SQL'
SELECT table_schema,
       table_name,
       ordinal_position,
       column_name,
       data_type,
       is_nullable,
       column_default
  FROM information_schema.columns
 WHERE table_schema NOT IN ('information_schema','pg_catalog')
 ORDER BY table_schema, table_name, ordinal_position;
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  copy_query_to_file "${POSTGRES_DB:-postgres}" "${query}" "${target_path}"
  echo "Schema snapshot written to ${target_path}" >&2
}

audit_replication_lag() {
  ensure_env
  local target_path=${1:-}
  local lag_warn_seconds=${2:-300}
  local query
query=$(cat <<SQL
SELECT now() AS collected_at,
       application_name,
       client_addr,
       state,
       sync_state,
       write_lag,
       flush_lag,
       replay_lag,
       CASE WHEN write_lag IS NOT NULL AND write_lag > interval '${lag_warn_seconds} seconds' THEN 'lagging' ELSE 'ok' END AS status
  FROM pg_stat_replication
 ORDER BY application_name;
SQL
)
  if [[ -z ${target_path} ]]; then
    compose_exec env PGHOST="${POSTGRES_HOST}" PGPASSWORD="${POSTGRES_SUPERUSER_PASSWORD:-}" \
      psql --username "${POSTGRES_SUPERUSER:-postgres}" --dbname "${POSTGRES_DB:-postgres}" --csv --command "${query};"
    return
  fi
  compose_exec bash -lc "mkdir -p '$(dirname "${target_path}")'"
  copy_query_to_file "${POSTGRES_DB:-postgres}" "${query}" "${target_path}"
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
SELECT format('%s %s %s %s', type, auth_method, COALESCE(array_to_string(user_name,','),'<all>'), COALESCE(address,'<all>'))
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
SELECT format('%s %s %s %s', type, auth_method, COALESCE(array_to_string(user_name,','),'<all>'), COALESCE(address,'<all>'))
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
  compose_exec env TARGET_DIR="${container_dir}" python3 <<'PY'
import csv
import glob
import os
import sys

target = os.environ['TARGET_DIR']
files = sorted(glob.glob(os.path.join(target, 'postgresql-*.csv')))
if not files:
    sys.exit(0)

events = []
counts = {}
for path in files:
    with open(path, newline='') as fh:
        reader = csv.DictReader(fh)
        if not reader or 'message' not in reader.fieldnames:
            continue
        for row in reader:
            message = row.get('message', '')
            if 'pgaudit' in message:
                user = row.get('user_name') or 'unknown'
                counts[user] = counts.get(user, 0) + 1
                events.append(message)

if not events:
    sys.exit(0)

events_path = os.path.join(target, 'pgaudit_events.log')
with open(events_path, 'w') as fh:
    fh.write('\n'.join(events))

summary_path = os.path.join(target, 'pgaudit_summary.csv')
with open(summary_path, 'w', newline='') as fh:
    writer = csv.writer(fh)
    writer.writerow(['role', 'events'])
    for role, count in sorted(counts.items()):
        writer.writerow([role, count])
PY
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
